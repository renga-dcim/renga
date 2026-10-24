defmodule Renga.Transfers.Import do
  @moduledoc """
  Imports an organization's export archive into an empty organization
  (RFD 20).

  The archive is opened and validated whole (`Renga.Transfers.Archive`,
  `Renga.Transfers.Validation`) before anything is written. Then one
  transaction, holding the organization's row and its revision lock,
  rechecks that the organization is empty and that no archive ID exists
  anywhere in the deployment, and writes every record type in dependency
  order. The import lands whole or the organization stays as it was.

  Records keep their IDs and timestamps, with these exceptions:

    * Revisions and event sequence numbers are reallocated from this
      deployment, in source order, so they stay unique and ordered; the
      revision a resource snapshot embeds follows its revision.
    * People are principals, never destination accounts. A field that names
      a person is left empty and the principal it named is recorded in
      `imported_attributions`; imported Activity also names the principal's
      email and the import. `job_events`, whose actor must be set, names the
      principal's ID here instead. Memberships, team memberships, role
      assignments, and private saved views wait in `imported_held_records`
      until their person is linked.
    * Security state starts over: intake keys arrive revoked, approved
      installation keys pending, and active bindings revoked as imported, so
      people at the destination approve each again. Imported jobs are
      history (`imported_at`) and never lease, retry, or run.
    * Settings are applied only where they do not weaken the destination's;
      the rest are held on the import for an owner to confirm. A security
      setting (RFD 19) applies only when it adds a requirement, such as
      requiring MFA.

  Callers authorize the import and record it outside the organization, as
  `Renga.Transfers.Export` leaves to its callers.
  """

  import Ecto.Query

  alias Renga.Accounts.Organization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Changes
  alias Renga.Inventory.ResourceStore
  alias Renga.Jobs
  alias Renga.Repo
  alias Renga.SecuritySettings
  alias Renga.Transfers.Archive
  alias Renga.Transfers.OrganizationImport
  alias Renga.Transfers.RecordTypes
  alias Renga.Transfers.Schema
  alias Renga.Transfers.Validation

  @batch_records 500
  @batch_bytes 8 * 1024 * 1024
  @id_batch 10_000

  # Records that only apply to a person once their principal is linked.
  @held_types ~w(organization_memberships team_memberships role_assignments)

  # Fields written empty and set once every record type is in: a finalized
  # catalog revision refuses new component templates.
  @post_fields %{"catalog_type_revisions" => ~w(finalized_at)}

  # Event streams numbered from their own sequence.
  @sequence_types ~w(cable_assertions cable_change_events module_installation_events)

  # Person fields a record cannot leave empty: an imported record names the
  # principal in the column beside it.
  @principal_columns %{
    {"cable_assertions", "actor_user_id"} => "actor_principal_id",
    {"desired_module_assignments", "confirmed_by_user_id"} => "confirmed_by_principal_id",
    {"expected_component_exceptions", "confirmed_by_user_id"} => "confirmed_by_principal_id"
  }

  # Rows an empty organization may already have: its Activity, the person
  # importing, and security settings its owner already turned on.
  @allowed_before ~w(change_events organization_memberships role_assignments
                     organization_security_settings)

  @doc """
  Imports the archive at `path` into `organization`.

  Options:

    * `:imported_by_user_id` - the owner importing; their own membership
      does not make the organization non-empty
    * `:operator` - the operator importing, as recorded in Activity
    * `:authorize` - a function run first inside the import's transaction,
      which may roll it back
    * `:tmp_dir` - where the archive is expanded

  Returns `{:ok, %OrganizationImport{}}` or `{:error, reason}`, where reason
  is `{:invalid, problems}`, `:not_empty`, `{:id_collisions, counts}` (the
  number of existing IDs by record type), or what `:authorize` rolled back
  with.
  """
  def run(%Organization{} = organization, path, opts \\ []) do
    case Archive.open(path, Keyword.take(opts, [:tmp_dir])) do
      {:ok, archive} ->
        try do
          with :ok <- validate(archive),
               do: apply_archive(archive, organization, sha256(path), opts)
        after
          Archive.close(archive)
        end

      {:error, problems} ->
        {:error, {:invalid, problems}}
    end
  end

  defp validate(archive) do
    case Validation.validate(archive) do
      :ok -> :ok
      {:error, problems} -> {:error, {:invalid, problems}}
    end
  end

  defp sha256(path) do
    path
    |> File.stream!(1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp apply_archive(archive, organization, sha256, opts) do
    types = RecordTypes.included(archive.manifest["parts"])

    state = %{
      archive: archive,
      organization_id: organization.id,
      opts: opts,
      now: Renga.Time.utc_now_ms(),
      types: types,
      columns: Schema.columns(),
      self_references: self_references(types),
      map: :ets.new(__MODULE__, [:set, :private]),
      import: nil
    }

    try do
      Repo.transaction(fn -> write(state, sha256) end, timeout: :infinity)
      |> Changes.broadcast(organization.id)
    after
      :ets.delete(state.map)
    end
  end

  defp write(state, sha256) do
    Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
      "#{Repo.background_statement_timeout_ms()}ms"
    ])

    organization = lock_organization!(state.organization_id)
    Keyword.get(state.opts, :authorize, fn -> :ok end).()
    ensure_empty!(state)
    ensure_no_collisions!(state)

    {settings, held_settings} = settings(organization, organization_record(state))
    held_settings = hold_security_settings(held_settings, state)
    state = %{state | import: insert_import!(state, sha256, held_settings)}
    update_organization!(organization, organization_record(state), settings)
    insert_principals!(state)
    allocate_revisions!(state)
    Enum.each(@sequence_types, &allocate_sequence!(state, &1))
    Enum.each(state.types, &insert_type!(state, &1))
    set_later_fields!(state)
    record_import!(state)
    state.import
  end

  defp lock_organization!(organization_id) do
    Organization
    |> where([organization], organization.id == ^organization_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  ## Preconditions

  defp ensure_empty!(state) do
    params = [Ecto.UUID.dump!(state.organization_id)]

    occupied? =
      Enum.any?(RecordTypes.all(), fn type ->
        type.name not in @allowed_before and exists?(type.name, "", params)
      end) or
        exists?("organization_imports", "", params) or
        others?("organization_memberships", "t.user_id", state, params) or
        others?(
          "role_assignments",
          "(SELECT m.user_id FROM organization_memberships AS m WHERE m.id = t.membership_id)",
          state,
          params
        )

    if occupied?, do: Repo.rollback(:not_empty)
  end

  defp others?(table, user_sql, state, params) do
    case state.opts[:imported_by_user_id] do
      nil ->
        exists?(table, "", params)

      user_id ->
        exists?(
          table,
          " AND #{user_sql} IS DISTINCT FROM $2",
          params ++ [Ecto.UUID.dump!(user_id)]
        )
    end
  end

  defp exists?(table, condition, params) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM #{quote_name(table)} AS t " <>
          "WHERE t.organization_id = $1#{condition})",
        params
      )

    exists?
  end

  # Records keep their IDs, so none may exist anywhere in the deployment.
  # Importing a copy with new IDs is future work.
  defp ensure_no_collisions!(state) do
    counts =
      for type <- state.types,
          "id" in type.fields,
          count = collisions(state.archive, type.name),
          count > 0,
          do: {type.name, count}

    if counts != [], do: Repo.rollback({:id_collisions, counts})
  end

  defp collisions(archive, type) do
    archive
    |> Archive.records(type)
    |> Stream.map(&Ecto.UUID.dump!(&1["id"]))
    |> Stream.chunk_every(@id_batch)
    |> Enum.reduce(0, fn ids, count ->
      %{rows: [[found]]} =
        Repo.query!("SELECT count(*) FROM #{quote_name(type)} WHERE id = ANY($1)", [ids])

      count + found
    end)
  end

  ## The organization and its import

  defp organization_record(state),
    do: state.archive |> Archive.records("organization") |> Enum.at(0)

  # Portable settings apply unless they would let the organization do
  # something it cannot now: capabilities the destination does not allow
  # are held for an owner. Settings this release does not know are held too.
  defp settings(organization, record) do
    source = record["settings"] || %{}
    {jobs, held_jobs} = job_settings(organization, Map.get(source, "jobs", %{}))
    held = Map.drop(source, ["jobs"])
    held = if held_jobs == %{}, do: held, else: Map.put(held, "jobs", held_jobs)

    settings =
      if jobs == %{}, do: organization.settings || %{}, else: put_jobs(organization, jobs)

    {settings, held}
  end

  defp job_settings(organization, source) when is_map(source) do
    current = Jobs.Settings.allowed_capabilities(organization)

    {allowed, held_allowed} =
      case source["allowed_capabilities"] do
        allowed when is_list(allowed) -> Enum.split_with(allowed, &(&1 in current))
        _default -> {nil, []}
      end

    retention =
      case source["retention_days"] do
        days when is_integer(days) and days > 0 -> days
        _default -> nil
      end

    applied =
      %{"allowed_capabilities" => allowed, "retention_days" => retention}
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    held =
      if held_allowed == [], do: %{}, else: %{"allowed_capabilities" => held_allowed}

    {applied, held}
  end

  defp job_settings(_organization, _source), do: {%{}, %{}}

  # Security settings that would not add a requirement are held, by name,
  # unless the destination already has the same value; so are settings this
  # release does not know.
  defp hold_security_settings(held, state) do
    security =
      if Enum.any?(state.types, &(&1.name == "organization_security_settings")) do
        for record <- Archive.records(state.archive, "organization_security_settings"),
            not adds_requirement?(record),
            differs?(state.organization_id, record["name"], record["value"]["value"]),
            into: %{},
            do: {record["name"], record["value"]["value"]}
      else
        %{}
      end

    if security == %{}, do: held, else: Map.put(held, "security", security)
  end

  # A setting that is off by default adds a requirement when turned on.
  defp adds_requirement?(%{"name" => name, "value" => %{"value" => true}}) do
    case SecuritySettings.parse_name(name) do
      {:ok, name} ->
        match?(%{type: :boolean, default: false}, SecuritySettings.definitions()[name])

      :error ->
        false
    end
  end

  defp adds_requirement?(_record), do: false

  defp differs?(organization_id, name, value) do
    case SecuritySettings.parse_name(name) do
      {:ok, name} -> SecuritySettings.get(organization_id, name) != value
      :error -> true
    end
  end

  defp put_jobs(organization, jobs) do
    Jobs.Settings.put(organization, %{
      allowed_capabilities:
        Map.get(jobs, "allowed_capabilities", Jobs.Settings.allowed_capabilities(organization)),
      retention_days: Map.get(jobs, "retention_days", Jobs.Settings.retention_days(organization))
    })
  end

  # The destination keeps its own name and slug. Opting into
  # guest-without-VM findings only adds findings, so it applies as is.
  defp update_organization!(organization, record, settings) do
    organization
    |> Ecto.Changeset.cast(record, [
      :default_accent,
      :default_power_factor,
      :guest_without_vm_findings
    ])
    |> Ecto.Changeset.put_change(:settings, settings)
    |> Repo.update!()
  end

  defp insert_import!(state, sha256, held_settings) do
    manifest = state.archive.manifest
    source = manifest["organization"]
    {:ok, snapshot_at, 0} = DateTime.from_iso8601(manifest["snapshot_at"])

    Repo.insert!(%OrganizationImport{
      organization_id: state.organization_id,
      source_organization_id: source["id"],
      source_slug: source["slug"],
      source_name: source["name"],
      format_version: manifest["format_version"],
      renga_version: manifest["renga_version"],
      snapshot_at: snapshot_at,
      parts: manifest["parts"],
      records: manifest["files"] |> Map.values() |> Enum.map(& &1["records"]) |> Enum.sum(),
      sha256: sha256,
      source_settings: organization_record(state)["settings"] || %{},
      held_settings: held_settings,
      imported_by_user_id: state.opts[:imported_by_user_id],
      operator: state.opts[:operator]
    })
  end

  defp record_import!(state) do
    record = state.import

    %ChangeEvent{
      organization_id: state.organization_id,
      actor_user_id: record.imported_by_user_id
    }
    |> ChangeEvent.changeset(%{
      kind: "imported",
      metadata:
        %{
          "import_id" => record.id,
          "source" => record.source_slug,
          "records" => record.records,
          "operator" => record.operator
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      occurred_at: state.now
    })
    |> Repo.insert!()
  end

  ## Principals

  defp insert_principals!(state) do
    state.archive
    |> Archive.records("principals")
    |> Stream.map(fn principal ->
      id = Ecto.UUID.generate()
      :ets.insert(state.map, {{:principal, principal["id"]}, id, principal["email"]})

      %{
        "id" => id,
        "organization_id" => state.organization_id,
        "organization_import_id" => state.import.id,
        "source_id" => principal["id"],
        "email" => principal["email"],
        "inserted_at" => state.now,
        "updated_at" => state.now
      }
    end)
    |> insert_rows!("imported_principals")
  end

  defp principal!(state, source_id) do
    [{_key, id, email}] = :ets.lookup(state.map, {:principal, source_id})
    {id, email}
  end

  ## Revisions and sequences

  defp allocate_revisions!(state) do
    included = Enum.map(state.types, & &1.name)

    sources =
      [{"resources", "resource_version"}, {"resource_revisions", "revision"}]
      |> Enum.filter(fn {type, _field} -> type in included end)
      |> Enum.flat_map(fn {type, field} ->
        state.archive |> Archive.records(type) |> Enum.map(& &1[field])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    allocated = ResourceStore.allocate_revisions!(state.organization_id, length(sources))
    remember(state, :revision, sources, allocated)
  end

  defp allocate_sequence!(state, type) do
    if Enum.any?(state.types, &(&1.name == type)) do
      sources =
        state.archive
        |> Archive.records(type)
        |> Enum.map(& &1["sequence"])
        |> Enum.uniq()
        |> Enum.sort()

      %{rows: rows} =
        Repo.query!(
          "SELECT nextval(pg_get_serial_sequence($1, 'sequence')) FROM generate_series(1, $2)",
          [type, length(sources)]
        )

      remember(state, {:sequence, type}, sources, rows |> Enum.map(&hd/1) |> Enum.sort())
    end
  end

  defp remember(state, kind, sources, allocated) do
    sources
    |> Enum.zip(allocated)
    |> Enum.each(fn {source, value} -> :ets.insert(state.map, {{kind, source}, value}) end)
  end

  defp mapped(state, kind, source) do
    [{_key, value}] = :ets.lookup(state.map, {kind, source})
    value
  end

  ## Record types

  defp self_references(types) do
    types
    |> Schema.references()
    |> Enum.filter(&(&1.type == &1.target))
    |> Map.new(fn reference ->
      {field, "id"} =
        reference.fields |> Enum.zip(reference.target_fields) |> List.keyfind("id", 1)

      {reference.type, field}
    end)
  end

  defp insert_type!(state, %{name: name} = type) when name in @held_types,
    do: hold_type!(state, type)

  defp insert_type!(state, %{name: "organization_security_settings"} = type) do
    applied = state.archive |> Archive.records(type.name) |> Enum.filter(&adds_requirement?/1)
    changed = Enum.filter(applied, &differs?(state.organization_id, &1["name"], true))

    # The source's value replaces the destination's row for the setting,
    # which can only have been off or already the same.
    Repo.query!(
      "DELETE FROM organization_security_settings WHERE organization_id = $1 AND name = ANY($2)",
      [Ecto.UUID.dump!(state.organization_id), Enum.map(applied, & &1["name"])]
    )

    insert_records!(applied, state, type)
    Enum.each(changed, &record_setting_change!(state, &1["name"]))
    :ok
  end

  defp insert_type!(state, type) do
    case Map.fetch(state.self_references, type.name) do
      {:ok, parent_field} ->
        insert_by_level!(state, type, parent_field)

      :error ->
        state.archive |> Archive.records(type.name) |> insert_records!(state, type)
        :ok
    end
  end

  # Activity shows each change to a security setting, so a requirement the
  # import turned on is recorded as one, by the owner importing; until then
  # the setting was off.
  defp record_setting_change!(state, name) do
    %ChangeEvent{
      organization_id: state.organization_id,
      actor_user_id: state.import.imported_by_user_id
    }
    |> ChangeEvent.changeset(%{
      kind: "security_setting_changed",
      field: name,
      old_value: %{"value" => false},
      new_value: %{"value" => true},
      metadata: %{
        "reason" => "imported from #{state.import.source_slug}",
        "import_id" => state.import.id
      },
      occurred_at: state.now
    })
    |> Repo.insert!()
  end

  # A record that refers to another of its type goes in after it, a level
  # at a time; some such types refuse updates, so the reference cannot be
  # set afterwards.
  defp insert_by_level!(state, type, parent_field) do
    expected = state.archive.manifest["files"][Archive.record_file(type.name)]["records"]
    insert_levels!(state, type, parent_field, 0, expected)
  end

  defp insert_levels!(_state, _type, _parent_field, done, expected) when done >= expected,
    do: :ok

  defp insert_levels!(state, type, parent_field, done, expected) do
    count =
      state.archive
      |> Archive.records(type.name)
      |> Stream.reject(&inserted?(state, type.name, &1["id"]))
      |> Stream.filter(fn record ->
        is_nil(record[parent_field]) or inserted?(state, type.name, record[parent_field])
      end)
      |> insert_records!(state, type, fn records ->
        Enum.each(records, &:ets.insert(state.map, {{:inserted, type.name, &1["id"]}}))
      end)

    if count == 0, do: raise("#{type.name} records refer to each other in a cycle")
    insert_levels!(state, type, parent_field, done + count, expected)
  end

  defp inserted?(state, type, id), do: :ets.member(state.map, {:inserted, type, id})

  # Inserts records a batch at a time with the people they name and the
  # records held for their person, calling `after_batch` with each batch.
  # Returns how many records it read.
  defp insert_records!(records, state, type, after_batch \\ fn _records -> :ok end) do
    records
    |> Stream.chunk_every(@batch_records)
    |> Enum.reduce(0, fn batch, count ->
      prepared = Enum.map(batch, &prepare(state, type, &1))

      rows = for {:insert, row, _named} <- prepared, do: encode(row, state.columns[type.name])
      attributions = for {:insert, _row, named} <- prepared, attribution <- named, do: attribution
      held = for {:hold, row} <- prepared, do: row

      insert_rows!(rows, type.name)
      insert_rows!(attributions, "imported_attributions")
      insert_rows!(held, "imported_held_records")

      after_batch.(batch)
      count + length(batch)
    end)
  end

  defp hold_type!(state, type) do
    state.archive
    |> Archive.records(type.name)
    |> Stream.map(fn record ->
      principal = holder(state, type.name, record)

      if type.name == "organization_memberships",
        do: :ets.insert(state.map, {{:membership, record["id"]}, record["user_id"]})

      held_row(state, principal, type.name, record)
    end)
    |> insert_rows!("imported_held_records")
  end

  defp holder(_state, "organization_memberships", record), do: record["user_id"]

  defp holder(state, _type, record) do
    [{_key, user_id}] = :ets.lookup(state.map, {:membership, record["membership_id"]})
    user_id
  end

  defp held_row(state, principal_source_id, type, record) do
    {principal_id, _email} = principal!(state, principal_source_id)

    %{
      "id" => Ecto.UUID.generate(),
      "organization_id" => state.organization_id,
      "principal_id" => principal_id,
      "record_type" => type,
      "record" => record
    }
  end

  # Turns one archive record into the row to insert, with the people it
  # names, or holds it for its person.
  defp prepare(state, %{name: "saved_views"}, %{"user_id" => user_id} = record)
       when is_binary(user_id),
       do: {:hold, held_row(state, user_id, "saved_views", record)}

  defp prepare(state, type, record) do
    {row, named} =
      record
      |> secure(type.name, state)
      |> renumber(type.name, state)
      |> leave_for_later(type)
      |> Map.put("organization_id", state.organization_id)
      |> mark_imported(type.name, state)
      |> attribute(type, state)

    {:insert, row, named}
  end

  defp secure(record, "intake_api_keys", _state) do
    # The key's token never left the source; nothing can present it here.
    Map.merge(record, %{
      "status" => "revoked",
      "token_hash" => Base.encode64(:crypto.strong_rand_bytes(32))
    })
  end

  defp secure(%{"status" => "approved"} = record, "installation_keys", _state),
    do:
      Map.merge(record, %{
        "status" => "pending",
        "approved_at" => nil,
        "approved_by_user_id" => nil
      })

  defp secure(%{"status" => "active"} = record, "target_bindings", state) do
    Map.merge(record, %{
      "status" => "revoked",
      "revoked_at" => timestamp(state.now),
      "revoked_reason" => "imported",
      "revoked_by_user_id" => nil
    })
  end

  # Trust in a source's cabling is granted at the destination, not carried.
  defp secure(%{"revoked_at" => nil} = record, "cable_import_contracts", state),
    do: Map.merge(record, %{"revoked_at" => timestamp(state.now), "revoked_by_id" => nil})

  defp secure(record, "jobs", state) do
    # A leased job keeps its shape with a lease token no one holds.
    lease =
      if record["state"] in Jobs.Job.leased_states(),
        do: Base.encode64(:crypto.strong_rand_bytes(32))

    Map.merge(record, %{
      "imported_at" => timestamp(state.now),
      "lease_token_hash" => lease,
      "offer_expires_at" => nil
    })
  end

  defp secure(record, _type, _state), do: record

  defp renumber(record, "resources", state),
    do: Map.update!(record, "resource_version", &mapped(state, :revision, &1))

  defp renumber(record, "resource_revisions", state) do
    revision = mapped(state, :revision, record["revision"])

    snapshot =
      case record["snapshot"] do
        %{"resource_version" => version} = snapshot when is_integer(version) ->
          %{snapshot | "resource_version" => mapped(state, :revision, version)}

        snapshot ->
          snapshot
      end

    %{record | "revision" => revision, "snapshot" => snapshot}
  end

  defp renumber(record, type, state) when type in @sequence_types,
    do: Map.update!(record, "sequence", &mapped(state, {:sequence, type}, &1))

  defp renumber(record, _type, _state), do: record

  defp leave_for_later(record, type) do
    fields = type.deferred_fields ++ Map.get(@post_fields, type.name, [])
    Map.merge(record, Map.new(fields, &{&1, nil}))
  end

  # Imported Activity says so and names its import.
  defp mark_imported(row, "change_events", state) do
    imported = %{"import_id" => state.import.id}
    Map.put(row, "metadata", Map.put(row["metadata"] || %{}, "imported", imported))
  end

  defp mark_imported(row, _type, _state), do: row

  # Fields that name a person are emptied and the principal recorded. A
  # batch takes its columns from its first row, so every row of a type
  # carries its principal columns, even one that names no one.
  defp attribute(record, type, state) do
    record =
      for {{name, _field}, column} <- @principal_columns, name == type.name, reduce: record do
        record -> Map.put_new(record, column, nil)
      end

    Enum.reduce(type.principal_fields, {record, []}, fn {field, condition}, {row, named} ->
      source_id = row[field]

      if is_binary(source_id) and names_person?(row, condition) do
        {principal_id, email} = principal!(state, source_id)
        row = person_field(row, type.name, field, principal_id, email, state)
        {row, named ++ [attribution(state, type.name, row["id"], field, principal_id)]}
      else
        {row, named}
      end
    end)
  end

  defp names_person?(_record, nil), do: true
  defp names_person?(record, {field, value}), do: record[field] == value

  # A job event's actor must be set; it names the principal, which is no
  # account.
  defp person_field(row, "job_events", field, principal_id, _email, _state),
    do: Map.put(row, field, principal_id)

  defp person_field(row, "change_events", field, _principal_id, email, _state) do
    row
    |> Map.put(field, nil)
    |> put_in(["metadata", "imported", "actor"], email || "a former member")
  end

  defp person_field(row, type, field, principal_id, _email, _state)
       when is_map_key(@principal_columns, {type, field}) do
    row
    |> Map.put(field, nil)
    |> Map.put(@principal_columns[{type, field}], principal_id)
  end

  defp person_field(row, _type, field, _principal_id, _email, _state),
    do: Map.put(row, field, nil)

  defp attribution(state, type, record_id, field, principal_id) do
    %{
      "organization_id" => state.organization_id,
      "record_type" => type,
      "record_id" => record_id,
      "field" => field,
      "principal_id" => principal_id
    }
  end

  # Fields left empty on insert, set once every record they refer to is in.
  defp set_later_fields!(state) do
    for type <- state.types,
        fields = type.deferred_fields ++ Map.get(@post_fields, type.name, []),
        fields != [] do
      state.archive
      |> Archive.records(type.name)
      |> Stream.filter(fn record -> Enum.any?(fields, &(not is_nil(record[&1]))) end)
      |> Stream.map(&Map.take(&1, ["id" | fields]))
      |> Stream.map(&encode(&1, state.columns[type.name]))
      |> batches()
      |> Enum.each(fn {batch, _fields} ->
        assignments = Enum.map_join(fields, ", ", &"#{quote_name(&1)} = d.#{quote_name(&1)}")

        Repo.query!(
          "UPDATE #{quote_name(type.name)} AS t SET #{assignments} " <>
            "FROM jsonb_populate_recordset(NULL::#{quote_name(type.name)}, $1::text::jsonb) AS d " <>
            "WHERE t.id = d.id",
          [batch]
        )
      end)
    end
  end

  ## Writing rows

  # Archive values are JSON; PostgreSQL reads them into each column's type,
  # except binary values, which the archive holds in base64.
  defp encode(row, columns) do
    Map.new(row, fn {field, value} ->
      case columns[field] do
        %{type: "bytea"} when is_binary(value) ->
          {field, "\\x" <> Base.encode16(Base.decode64!(value), case: :lower)}

        _column ->
          {field, value}
      end
    end)
  end

  # Every row of a table has the same fields, which name its columns.
  defp insert_rows!(rows, table) do
    rows
    |> batches()
    |> Enum.each(fn {batch, fields} ->
      columns = Enum.map_join(fields, ", ", &quote_name/1)

      Repo.query!(
        "INSERT INTO #{quote_name(table)} (#{columns}) SELECT #{columns} " <>
          "FROM jsonb_populate_recordset(NULL::#{quote_name(table)}, $1::text::jsonb)",
        [batch]
      )
    end)
  end

  # JSON arrays of rows, each at most @batch_records rows and about
  # @batch_bytes, with the fields of their first row.
  defp batches(rows) do
    rows
    |> Stream.map(&{Renga.JSON.encode!(&1), Map.keys(&1)})
    |> Stream.chunk_while(
      {[], 0, 0, nil},
      fn {json, fields}, {batch, count, bytes, first} ->
        acc = {[json | batch], count + 1, bytes + byte_size(json), first || fields}

        if count + 1 >= @batch_records or bytes + byte_size(json) >= @batch_bytes,
          do: {:cont, emit(acc), {[], 0, 0, nil}},
          else: {:cont, acc}
      end,
      fn
        {[], _count, _bytes, _fields} -> {:cont, {[], 0, 0, nil}}
        acc -> {:cont, emit(acc), {[], 0, 0, nil}}
      end
    )
  end

  defp emit({batch, _count, _bytes, fields}), do: {wrap(batch), fields}

  defp wrap(batch),
    do: IO.iodata_to_binary(["[", Enum.intersperse(Enum.reverse(batch), ","), "]"])

  defp timestamp(at), do: DateTime.to_iso8601(at)

  defp quote_name(name) do
    unless Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name),
      do: raise(ArgumentError, "unsafe SQL name #{inspect(name)}")

    ~s("#{name}")
  end
end
