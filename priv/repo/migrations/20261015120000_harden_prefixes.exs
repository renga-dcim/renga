defmodule Renga.Repo.Migrations.HardenPrefixes do
  @moduledoc """
  RFD 4, Phase 1: one prefix per CIDR in each routing table, and the
  `container` status.

  Until VRFs replace the free-text `vrf` column (Phase 2), a routing table
  is the exact stored string, with null meaning the global table; `NULLS NOT
  DISTINCT` makes two global rows collide. Existing duplicates are not
  merged or deleted here: the migration stops and names them so an operator
  can decide which record to keep.
  """
  use Ecto.Migration

  def up do
    report_duplicate_prefixes!()

    create unique_index(:prefixes, [:organization_id, :vrf, :prefix],
             name: :prefixes_organization_vrf_prefix_index,
             nulls_distinct: false
           )

    create constraint(:prefixes, :prefixes_valid_status,
             check: "status IN ('container', 'active', 'reserved', 'deprecated')"
           )
  end

  def down do
    drop constraint(:prefixes, :prefixes_valid_status)

    drop index(:prefixes, [:organization_id, :vrf, :prefix],
           name: :prefixes_organization_vrf_prefix_index
         )
  end

  defp report_duplicate_prefixes! do
    %{rows: rows} =
      repo().query!("""
      SELECT organization_id::text, coalesce(vrf, '(global)'), prefix::text, count(*)
      FROM prefixes
      GROUP BY organization_id, vrf, prefix
      HAVING count(*) > 1
      ORDER BY 1, 2, 3
      """)

    if rows != [] do
      duplicates =
        Enum.map_join(rows, "\n", fn [organization_id, vrf, prefix, count] ->
          "  organization #{organization_id}, table #{vrf}: #{prefix} (#{count} records)"
        end)

      raise """
      Duplicate prefixes must be resolved before each routing table can hold
      one record per CIDR. Keep one record per line below, and delete or
      change the others:

      #{duplicates}
      """
    end
  end
end
