defmodule Renga.Repo.Migrations.CreateVrfs do
  @moduledoc """
  RFD 4, Phase 2: VRF records replace the free-text `prefixes.vrf`.

  Each legacy routing-table string maps to a namespace: trimmed, compared
  case-insensitively, with blank and `default` meaning the global table
  (null `vrf_id`). The migration first runs a preflight over every
  organization and applies nothing while any namespace would be fed by more
  than one legacy spelling, including a `default` or blank table next to
  existing global prefixes. Operators approve such a merge by renaming the
  legacy tables to one spelling (blank for global) in the prefix edit form,
  then run the migration again; exact-CIDR clashes surface there as the
  usual "already exists" error. This keeps two isolated tables from being
  silently merged.

  Each remaining namespace becomes one VRF resource envelope, with its
  creation revision, and one typed VRF row; prefixes point at it through a
  tenant-safe foreign key, and their envelopes are relabelled to match. Uniqueness becomes one CIDR per organization and
  VRF, with the global table counted as one namespace.

  Rollback restores the schema and normalized namespace names, not original
  spellings: padded names stay trimmed and blank/default become null. Prefix
  relabel revisions remain; VRF envelopes and their revisions are removed.
  """
  use Ecto.Migration

  @resource_revision_lock_key 1_380_271_687

  # The revision snapshot `Renga.Inventory.ResourceStore` writes, in SQL.
  @snapshot """
  jsonb_build_object(
    'id', id, 'kind', kind, 'name', name, 'display_name', display_name,
    'lifecycle_state', lifecycle_state, 'spec', spec, 'generation', generation,
    'resource_version', resource_version, 'labels', labels,
    'annotations', annotations, 'deletion_requested_at', deletion_requested_at
  )
  """

  def up do
    create table(:vrfs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :vrfs_organization_resource_fkey
          ),
          null: false

      add :name, :string, null: false
      add :route_distinguisher, :string
      add :status, :string, null: false, default: "active"
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:vrfs, [:id, :organization_id])
    create unique_index(:vrfs, [:organization_id, :resource_id])

    create unique_index(:vrfs, [:organization_id, "lower(name)"],
             name: :vrfs_organization_name_index
           )

    create unique_index(:vrfs, [:organization_id, :route_distinguisher],
             name: :vrfs_organization_route_distinguisher_index,
             where: "route_distinguisher IS NOT NULL"
           )

    create constraint(:vrfs, :vrfs_valid_status, check: "status IN ('active', 'deprecated')")

    alter table(:prefixes) do
      add :vrf_id,
          references(:vrfs,
            with: [organization_id: :organization_id],
            on_delete: :restrict,
            type: :binary_id,
            name: :prefixes_tenant_vrf_fkey
          )
    end

    flush()

    namespaces = preflight!()
    execute_data_migration(namespaces)

    drop index(:prefixes, [:organization_id, :vrf, :prefix],
           name: :prefixes_organization_vrf_prefix_index
         )

    alter table(:prefixes) do
      remove :vrf
    end

    create unique_index(:prefixes, [:organization_id, :vrf_id, :prefix],
             name: :prefixes_organization_vrf_prefix_index,
             nulls_distinct: false
           )
  end

  def down do
    drop index(:prefixes, [:organization_id, :vrf_id, :prefix],
           name: :prefixes_organization_vrf_prefix_index
         )

    alter table(:prefixes) do
      add :vrf, :string
    end

    flush()

    repo().query!("""
    UPDATE prefixes SET vrf = vrfs.name
    FROM vrfs
    WHERE vrfs.id = prefixes.vrf_id AND vrfs.organization_id = prefixes.organization_id
    """)

    alter table(:prefixes) do
      remove :vrf_id
    end

    flush()

    repo().query!("DELETE FROM resources WHERE id IN (SELECT resource_id FROM vrfs)")

    drop table(:vrfs)

    create unique_index(:prefixes, [:organization_id, :vrf, :prefix],
             name: :prefixes_organization_vrf_prefix_index,
             nulls_distinct: false
           )
  end

  # Groups every legacy table by organization and namespace, and stops with
  # a remediation report when any namespace has more than one source.
  defp preflight! do
    %{rows: rows} =
      repo().query!("""
      SELECT organization_id::text, vrf, count(*)
      FROM prefixes
      GROUP BY organization_id, vrf
      ORDER BY 1, 2 NULLS FIRST
      """)

    namespaces =
      rows
      |> Enum.group_by(
        fn [organization_id, vrf, _count] -> {organization_id, namespace(vrf)} end,
        fn [_organization_id, vrf, count] -> {vrf, count} end
      )

    merges = Enum.filter(namespaces, fn {_key, sources} -> length(sources) > 1 end)

    if merges != [] do
      raise """
      Some routing tables would merge into one namespace. Approve each merge
      by renaming its tables to a single spelling (leave the routing table
      blank for Global) in the prefix edit form, then run the migration
      again. A CIDR that exists in more than one of the tables will be
      refused as already existing; delete or change one of them first.

      #{Enum.map_join(merges, "\n", &describe_merge/1)}
      """
    end

    namespaces
  end

  defp describe_merge({{organization_id, target}, sources}) do
    tables =
      Enum.map_join(sources, ", ", fn {vrf, count} ->
        "#{source_label(vrf)} (#{count} #{if count == 1, do: "prefix", else: "prefixes"})"
      end)

    "  organization #{organization_id}, #{target_label(target)}: #{tables}"
  end

  defp execute_data_migration(namespaces) do
    repo().query!("SELECT pg_advisory_xact_lock($1)", [@resource_revision_lock_key])

    for {{organization_id, {:vrf, _key}}, [{legacy, _count}]} <- namespaces do
      vrf_id = insert_vrf(organization_id, String.trim(legacy))

      repo().query!(
        "UPDATE prefixes SET vrf_id = $1 WHERE organization_id = $2 AND vrf = $3",
        [dump_uuid(vrf_id), dump_uuid(organization_id), legacy]
      )
    end

    # Blank and `default` tables are the global table, which is null.
    relabel_prefixes()
  end

  # Prefix envelopes are labelled with their CIDR and VRF, as the IPAM
  # context names them, so a legacy `default` or untrimmed table name does
  # not linger in a label. Each relabel is an envelope revision.
  defp relabel_prefixes do
    repo().query!("""
    WITH labels AS (
      SELECT prefixes.resource_id,
             CASE WHEN masklen(prefixes.prefix) = CASE family(prefixes.prefix) WHEN 4 THEN 32 ELSE 128 END
                  THEN host(prefixes.prefix)
                  ELSE prefixes.prefix::text
             END || coalesce(' (' || vrfs.name || ')', '') AS label
      FROM prefixes
      LEFT JOIN vrfs
        ON vrfs.id = prefixes.vrf_id AND vrfs.organization_id = prefixes.organization_id
    ), relabeled AS (
      UPDATE resources
      SET display_name = labels.label,
          resource_version = nextval('resource_revision_sequence'),
          updated_at = now()
      FROM labels
      WHERE resources.id = labels.resource_id
        AND resources.display_name IS DISTINCT FROM labels.label
      RETURNING resources.*
    )
    INSERT INTO resource_revisions
      (id, organization_id, resource_id, revision, action, generation, snapshot, inserted_at)
    SELECT gen_random_uuid(), organization_id, id, resource_version, 'updated', generation,
           #{@snapshot}, now()
    FROM relabeled
    """)

    :ok
  end

  defp insert_vrf(organization_id, name) do
    resource_id = Ecto.UUID.generate()
    vrf_id = Ecto.UUID.generate()

    repo().query!(
      """
      INSERT INTO resources
        (id, organization_id, kind, name, display_name, lifecycle_state, resource_version,
         inserted_at, updated_at)
      VALUES ($1, $2, 'vrf', $3, $4, 'active', nextval('resource_revision_sequence'), now(), now())
      """,
      [dump_uuid(resource_id), dump_uuid(organization_id), "vrf-" <> resource_id, name]
    )

    repo().query!(
      """
      INSERT INTO resource_revisions
        (id, organization_id, resource_id, revision, action, generation, snapshot, inserted_at)
      SELECT gen_random_uuid(), organization_id, id, resource_version, 'created', generation,
             #{@snapshot}, now()
      FROM resources WHERE id = $1
      """,
      [dump_uuid(resource_id)]
    )

    repo().query!(
      """
      INSERT INTO vrfs (id, organization_id, resource_id, name, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, now(), now())
      """,
      [dump_uuid(vrf_id), dump_uuid(organization_id), dump_uuid(resource_id), name]
    )

    vrf_id
  end

  defp namespace(nil), do: :global

  defp namespace(vrf) do
    case vrf |> String.trim() |> String.downcase() do
      key when key in ["", "default"] -> :global
      key -> {:vrf, key}
    end
  end

  defp source_label(nil), do: "Global (no table)"
  defp source_label(vrf), do: inspect(vrf)

  defp target_label(:global), do: "Global"
  defp target_label({:vrf, key}), do: "table #{inspect(key)}"

  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)
end
