defmodule Renga.Transfers.ImportTest do
  use Renga.DataCase, async: true

  import Renga.CatalogFixtures
  import Renga.JobsFixtures
  import Renga.TopologyFixtures

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Inventory
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.InstallationKey
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceRevision
  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias Renga.Jobs.TargetBinding
  alias Renga.ResourceGroups
  alias Renga.SavedViews
  alias Renga.SecuritySettings
  alias Renga.SecuritySettings.Setting
  alias Renga.Teams
  alias Renga.Topology
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Archive.Writer
  alias Renga.Transfers.Export
  alias Renga.Transfers.Import
  alias Renga.Transfers.OrganizationImport
  alias Renga.Transfers.Validation

  @moduletag :tmp_dir
  @collect "inventory.collect@1"

  setup do
    %{organization: source, scope: owner, system_scope: system_scope} =
      job_organization_fixture()

    agent = agent_fixture(source)
    resource = reported_resource_fixture(source, agent)
    %{binding: binding, key: key} = target_binding_fixture(source, agent)
    {:ok, {intake_key, _token}} = Inventory.create_intake_api_key(owner, %{name: "dc-a"})

    {:ok, queued} = Jobs.create_job(owner, agent.id, @collect, %{})
    {:ok, other} = Jobs.create_job(owner, agent.id, @collect, %{})
    {:ok, [{leased, _token}]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)
    queued = if leased.id == queued.id, do: other, else: queued

    {:ok, private_view} = SavedViews.create_view(owner, %{area: "inventory", name: "Mine"})

    {:ok, shared_view} =
      SavedViews.create_view(owner, %{area: "inventory", name: "Ours", shared: true})

    {:ok, team} = Teams.create_team(owner, %{name: "Network"})
    membership = Repo.get_by!(OrganizationMembership, user_id: owner.user.id)
    {:ok, _team_membership} = Teams.add_member(owner, team, membership.id)

    {server, _expected} =
      assigned_server_fixture(owner, "db-01", [%{kind: "memory", name: "DIMM A1", position: "A1"}])

    {_switch, %{"eth0" => eth0}} = device_fixture(owner, "switch", "sw-01", ["eth0"])
    {_host, %{"eth0" => host_eth0}} = device_fixture(owner, "server", "host-01", ["eth0"])
    cable_fixture(owner, eth0, host_eth0)
    prefix_fixture(owner, "10.0.0.0/24")

    {:ok, set} = ResourceGroups.create_group_set(owner, %{name: "Environment", exclusive: true})

    {:ok, group} =
      ResourceGroups.create_group(owner, %{name: "Production", group_set_id: set.id})

    {:ok, 1} = ResourceGroups.add_members(owner, group, [server.id])

    %{
      source: source,
      owner: owner,
      agent: agent,
      resource: resource,
      server: server,
      binding: binding,
      key: key,
      intake_key: intake_key,
      queued: queued,
      leased: leased,
      private_view: private_view,
      shared_view: shared_view
    }
  end

  defp export(context, parts \\ ~w(history)) do
    path = Path.join(context.tmp_dir, "export-#{System.unique_integer([:positive])}.tar.zst")
    assert {:ok, _summary} = Export.write(context.source, path, parts: parts)
    path
  end

  # Importing keeps IDs, so the source must be gone first, as it is when an
  # organization moves between deployments.
  defp export_and_remove(context, parts \\ ~w(history)) do
    path = export(context, parts)
    Repo.delete!(context.source)
    path
  end

  defp import_archive(path, target, opts \\ []) do
    Import.run(target, path, [operator: "ops@example.com", tmp_dir: tmp(path)] ++ opts)
  end

  defp tmp(path), do: Path.dirname(path)

  defp target, do: Renga.InventoryFixtures.organization_fixture()

  defp group_memberships(organization) do
    ResourceGroups.Membership
    |> where(organization_id: ^organization.id)
    |> select([m], {m.resource_id, m.view, m.group_id, m.group_set_id})
    |> order_by([m], [m.resource_id, m.view, m.group_id])
    |> Repo.all()
  end

  # Security setting changes recorded at the destination, not imported.
  defp setting_changes(organization) do
    ChangeEvent
    |> where(organization_id: ^organization.id, kind: "security_setting_changed")
    |> Repo.all()
    |> Enum.reject(& &1.metadata["imported"])
  end

  defp count(schema, organization),
    do: Repo.aggregate(where(schema, organization_id: ^organization.id), :count)

  test "an archive lands whole, with its records, history, and people", context do
    revisions_before =
      context.source |> resources_by_version() |> Enum.map(& &1.id)

    memberships_before = group_memberships(context.source)
    assert memberships_before != []

    path = export_and_remove(context)
    target = target()

    assert {:ok, %OrganizationImport{} = imported} = import_archive(path, target)
    assert imported.source_slug == context.source.slug
    assert imported.operator == "ops@example.com"

    # Records keep their IDs, in the target.
    assert %Resource{organization_id: organization_id} = Repo.get!(Resource, context.server.id)
    assert organization_id == target.id
    assert Repo.get!(Resource, context.resource.id).name == context.resource.name

    # Revisions are this deployment's, in the source's order, and every
    # snapshot names its own revision.
    assert target |> resources_by_version() |> Enum.map(& &1.id) == revisions_before

    for revision <- Repo.all(where(ResourceRevision, organization_id: ^target.id)),
        version = revision.snapshot["resource_version"],
        not is_nil(version) do
      assert revision.revision == version or
               Repo.exists?(where(ResourceRevision, revision: ^version))
    end

    # The people the archive named are principals, not accounts.
    principals =
      Repo.query!(
        "SELECT source_id, email, user_id FROM imported_principals WHERE organization_id = $1",
        [Ecto.UUID.dump!(target.id)]
      ).rows

    owner_id = Ecto.UUID.dump!(context.owner.user.id)
    assert [owner_id, context.owner.user.email, nil] in principals

    assert count(OrganizationMembership, target) == 0
    held = held_records(target)
    assert {"organization_memberships", context.owner.user.id} in held
    assert {"team_memberships", nil} in held
    assert {"saved_views", context.owner.user.id} in held

    shared = Repo.get!(Renga.SavedViews.SavedView, context.shared_view.id)
    assert shared.user_id == nil and shared.created_by_id == nil
    assert attributed?(target, "saved_views", shared.id, "created_by_id")
    refute Repo.get(Renga.SavedViews.SavedView, context.private_view.id)

    # Security state starts over.
    assert Repo.get!(IntakeApiKey, context.intake_key.id).status == "revoked"

    assert %InstallationKey{status: "pending", approved_at: nil} =
             Repo.get!(InstallationKey, context.key.id)

    assert %TargetBinding{status: "revoked", revoked_reason: "imported"} =
             Repo.get!(TargetBinding, context.binding.id)

    # A finalized catalog revision keeps its templates; cables keep the
    # claim behind them, made by a principal.
    assert [%{finalized_at: %DateTime{}}] =
             Repo.all(where(Renga.Catalog.TypeRevision, organization_id: ^target.id))

    assert count(Renga.Catalog.ComponentTemplate, target) == 1
    assert count(Renga.Topology.Cable, target) == 1

    # Resource groups keep their direct members and the effective
    # membership that access boundaries read (RFD 18).
    assert [%{group_set: %{exclusive: true}}] =
             ResourceGroups.Group
             |> where(organization_id: ^target.id)
             |> preload(:group_set)
             |> Repo.all()

    assert count(ResourceGroups.Member, target) == 1
    assert group_memberships(target) == memberships_before

    assert [[nil, principal_id]] =
             Repo.query!(
               "SELECT actor_user_id, actor_principal_id FROM cable_assertions WHERE organization_id = $1",
               [Ecto.UUID.dump!(target.id)]
             ).rows

    assert is_binary(principal_id)

    # Jobs are history.
    assert %Job{state: "queued", imported_at: %DateTime{}} = Repo.get!(Job, context.queued.id)
    assert %Job{state: "leased", imported_at: %DateTime{}} = Repo.get!(Job, context.leased.id)
    agent = Repo.get!(Inventory.Agent, context.agent.id)
    assert {:ok, []} = Jobs.lease_jobs(Renga.Accounts.scope_for(target), agent, [@collect], 10)

    # Activity is marked imported and names its people.
    imported_events = Repo.all(where(ChangeEvent, organization_id: ^target.id))
    assert Enum.all?(imported_events, &(&1.kind == "imported" or &1.metadata["imported"]))

    assert Enum.any?(
             imported_events,
             &(&1.metadata["imported"]["actor"] == context.owner.user.email)
           )

    assert [%ChangeEvent{metadata: %{"import_id" => import_id}}] =
             Enum.filter(imported_events, &(&1.kind == "imported"))

    assert import_id == imported.id

    # What landed exports again as a valid archive.
    again = Path.join(context.tmp_dir, "again.tar.zst")

    assert {:ok, _summary} =
             Export.write(Repo.get!(Organization, target.id), again, parts: ~w(history))

    assert {:ok, archive} = Archive.open(again, tmp_dir: context.tmp_dir)
    assert :ok = Validation.validate(archive)
    Archive.close(archive)
  end

  test "records that name a principal land beside records that do not", context do
    {:ok, source} = Inventory.create_source(context.owner, %{kind: "manual", name: "cabling"})
    {:ok, _contract} = Topology.grant_cable_import_contract(context.owner, source.id)
    {_switch, %{"eth1" => a}} = device_fixture(context.owner, "switch", "sw-02", ["eth1"])
    {_host, %{"eth1" => b}} = device_fixture(context.owner, "server", "host-02", ["eth1"])

    {:ok, _claim} =
      Topology.import_cable_assertion(context.owner, source.id, %{
        interface_a_id: a.id,
        interface_b_id: b.id
      })

    # The source's claim, which names no person, leads the batch.
    path =
      context
      |> export_and_remove()
      |> reorder(context, "cable_assertions", &(&1["kind"] == "operator"))

    target = target()
    assert {:ok, _imported} = import_archive(path, target)

    assert [["import", nil, nil], ["operator", nil, principal_id]] =
             Repo.query!(
               "SELECT kind, actor_user_id, actor_principal_id FROM cable_assertions " <>
                 "WHERE organization_id = $1 ORDER BY kind",
               [Ecto.UUID.dump!(target.id)]
             ).rows

    assert is_binary(principal_id)

    # The source's cabling is trusted only once someone here grants it.
    assert %{revoked_at: %DateTime{}} =
             Repo.get_by!(Renga.Topology.CableImportContract, source_id: source.id)

    %{scope: owner} = job_organization_for(target)

    assert {:error, :cable_import_not_granted} =
             Topology.import_cable_assertion(owner, source.id, %{
               interface_a_id: a.id,
               interface_b_id: b.id
             })
  end

  test "a security setting applies only when it adds a requirement", context do
    {:ok, true} = SecuritySettings.put(context.owner, :require_mfa, true, "policy")
    path = export_and_remove(context)

    # An owner who turned the setting off is overruled; one who left it at
    # the default is not asked.
    target = target()

    Repo.insert!(%Setting{
      organization_id: target.id,
      name: "require_mfa",
      value: %{"value" => false},
      changed_by: "owner@example.com"
    })

    assert {:ok, imported} = import_archive(path, target)
    assert SecuritySettings.require_mfa?(target.id)
    refute Map.has_key?(imported.held_settings, "security")

    assert [%Setting{changed_by_user_id: nil}] =
             Repo.all(where(Setting, organization_id: ^target.id))

    # The destination's Security history records the requirement turning
    # on, beside the source's own history, which arrives marked imported.
    assert [change] = setting_changes(target)
    assert change.new_value == %{"value" => true}
    assert change.metadata["import_id"] == imported.id
    assert change.metadata["reason"] == "imported from #{context.source.slug}"
  end

  test "a security setting that would lift a requirement is held", context do
    Repo.insert!(%Setting{
      organization_id: context.source.id,
      name: "require_mfa",
      value: %{"value" => false},
      changed_by: "owner@example.com"
    })

    path = export_and_remove(context)

    target = target()

    Repo.insert!(%Setting{
      organization_id: target.id,
      name: "require_mfa",
      value: %{"value" => true},
      changed_by: "owner@example.com"
    })

    assert {:ok, imported} = import_archive(path, target)
    assert SecuritySettings.require_mfa?(target.id)
    assert imported.held_settings["security"] == %{"require_mfa" => false}
    assert setting_changes(target) == []
  end

  test "an import is refused while any of its IDs exists", context do
    path = export(context)
    target = target()

    assert {:error, {:id_collisions, counts}} = import_archive(path, target)
    assert {"resources", _count} = List.keyfind(counts, "resources", 0)
    assert count(Resource, target) == 0
    refute Repo.exists?(where(OrganizationImport, organization_id: ^target.id))
  end

  test "only an empty organization takes an import", context do
    path = export_and_remove(context)
    target = target()
    %{scope: owner} = job_organization_for(target)

    {:ok, _resource} =
      Inventory.create_resource(owner, %{
        kind: "server",
        name: "already-here",
        lifecycle_state: "active"
      })

    assert {:error, :not_empty} = import_archive(path, target)
  end

  test "the importing owner's own membership leaves the organization empty", context do
    path = export_and_remove(context)
    target = target()
    %{scope: owner} = job_organization_for(target)

    assert {:error, :not_empty} = import_archive(path, target)
    assert {:ok, _imported} = import_archive(path, target, imported_by_user_id: owner.user.id)
  end

  test "an authorization refused in the transaction leaves nothing", context do
    path = export_and_remove(context)
    target = target()

    assert {:error, :forbidden} =
             import_archive(path, target, authorize: fn -> Repo.rollback(:forbidden) end)

    assert count(Resource, target) == 0
  end

  test "an invalid archive is refused before anything is written", context do
    path = Path.join(context.tmp_dir, "not-an-archive.tar.zst")
    File.write!(path, "nope")

    assert {:error, {:invalid, [_problem | _rest]}} = import_archive(path, target())
  end

  test "settings that would allow more than the destination does are held", context do
    operate = Jobs.Registry.keys_with_risk(:operate) |> List.first()
    assert operate, "a registered operate capability"

    source =
      context.source
      |> Ecto.Changeset.change(
        guest_without_vm_findings: true,
        settings: %{
          "jobs" => %{"allowed_capabilities" => [@collect, operate], "retention_days" => 30},
          "unknown" => true
        }
      )
      |> Repo.update!()

    path = export_and_remove(%{context | source: source})
    target = target()

    assert {:ok, imported} = import_archive(path, target)

    assert imported.held_settings == %{
             "jobs" => %{"allowed_capabilities" => [operate]},
             "unknown" => true
           }

    target = Repo.get!(Organization, target.id)
    assert Jobs.Settings.allowed_capabilities(target) == [@collect]
    assert Jobs.Settings.retention_days(target) == 30
    assert target.guest_without_vm_findings
  end

  # Rewrites the archive at `path` with `type`'s records sorted by `key`.
  defp reorder(path, context, type, key) do
    {:ok, archive} = Archive.open(path, tmp_dir: context.tmp_dir)

    try do
      writer =
        archive
        |> Archive.record_types()
        |> Enum.reduce(Writer.new(tmp_dir: context.tmp_dir), fn name, writer ->
          records = Enum.to_list(Archive.records(archive, name))
          records = if name == type, do: Enum.sort_by(records, key), else: records
          Writer.add_records(writer, name, records)
        end)

      %{"organization" => organization, "snapshot_at" => at, "parts" => parts} =
        archive.manifest

      {:ok, snapshot_at, 0} = DateTime.from_iso8601(at)
      reordered = Path.join(context.tmp_dir, "reordered.tar.zst")

      :ok =
        Writer.finish(
          writer,
          %{
            organization: %{
              id: organization["id"],
              slug: organization["slug"],
              name: organization["name"]
            },
            snapshot_at: snapshot_at,
            parts: parts
          },
          reordered
        )

      reordered
    after
      Archive.close(archive)
    end
  end

  defp job_organization_for(organization),
    do: %{scope: member_scope(organization, "owner")}

  defp resources_by_version(organization) do
    Resource
    |> where(organization_id: ^organization.id)
    |> order_by(asc: :resource_version)
    |> Repo.all()
  end

  defp held_records(organization) do
    Repo.query!(
      """
      SELECT h.record_type, p.source_id
      FROM imported_held_records AS h
      JOIN imported_principals AS p ON p.id = h.principal_id
      WHERE h.organization_id = $1
      """,
      [Ecto.UUID.dump!(organization.id)]
    ).rows
    |> Enum.map(fn [type, source_id] ->
      {type, if(type == "team_memberships", do: nil, else: Ecto.UUID.load!(source_id))}
    end)
  end

  defp attributed?(organization, type, record_id, field) do
    Repo.exists?(
      from a in "imported_attributions",
        where:
          a.organization_id == type(^organization.id, :binary_id) and a.record_type == ^type and
            a.record_id == type(^record_id, :binary_id) and a.field == ^field
    )
  end
end
