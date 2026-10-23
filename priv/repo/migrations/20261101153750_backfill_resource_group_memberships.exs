defmodule Renga.Repo.Migrations.BackfillResourceGroupMemberships do
  @moduledoc """
  Materializes inherited group membership for placements and containment that
  predate container inheritance. The migration refuses ambiguous exclusive
  memberships instead of silently choosing one group.
  """

  use Ecto.Migration

  def up do
    execute("""
    LOCK TABLE resource_group_sets, resource_groups, resource_group_members,
               resource_group_memberships, current_placements, sites, locations, racks
      IN SHARE MODE
    """)

    execute("""
    CREATE TEMP TABLE resource_group_memberships_backfill ON COMMIT DROP AS
    WITH RECURSIVE edges(organization_id, child, parent, trusted) AS (
      SELECT placement.organization_id, placement.resource_id, site.resource_id,
             placement.confirmed
        FROM current_placements AS placement
        JOIN sites AS site ON site.id = placement.site_id
      UNION ALL
      SELECT placement.organization_id, placement.resource_id, location.resource_id,
             placement.confirmed
        FROM current_placements AS placement
        JOIN locations AS location ON location.id = placement.location_id
      UNION ALL
      SELECT placement.organization_id, placement.resource_id, rack.resource_id,
             placement.confirmed
        FROM current_placements AS placement
        JOIN racks AS rack ON rack.id = placement.rack_id
      UNION ALL
      SELECT rack.organization_id, rack.resource_id, site.resource_id, true
        FROM racks AS rack
        JOIN sites AS site ON site.id = rack.site_id
      UNION ALL
      SELECT rack.organization_id, rack.resource_id, location.resource_id, true
        FROM racks AS rack
        JOIN locations AS location ON location.id = rack.location_id
      UNION ALL
      SELECT location.organization_id, location.resource_id, site.resource_id, true
        FROM locations AS location
        JOIN sites AS site ON site.id = location.site_id
      UNION ALL
      SELECT location.organization_id, location.resource_id, parent.resource_id, true
        FROM locations AS location
        JOIN locations AS parent ON parent.id = location.parent_id
    ),
    reach(organization_id, resource_id, container_id, trusted) AS (
      SELECT organization_id, child, parent, trusted FROM edges
      UNION
      SELECT reach.organization_id, reach.resource_id, edge.parent,
             reach.trusted AND edge.trusted
        FROM reach
        JOIN edges AS edge
          ON edge.organization_id = reach.organization_id
         AND edge.child = reach.container_id
    ),
    sources(organization_id, resource_id, member_id, view) AS (
      SELECT resource.organization_id, resource.id, resource.id, view.view
        FROM resources AS resource
       CROSS JOIN (VALUES ('inventory'), ('trusted')) AS view(view)
      UNION
      SELECT organization_id, resource_id, container_id, 'inventory' FROM reach
      UNION
      SELECT organization_id, resource_id, container_id, 'trusted'
        FROM reach
       WHERE trusted
    )
    SELECT DISTINCT source.organization_id, source.resource_id, source.view,
           member.group_id,
           CASE WHEN group_set.exclusive THEN group_set.id END AS group_set_id
      FROM sources AS source
      JOIN resource_group_members AS member
        ON member.organization_id = source.organization_id
       AND member.resource_id = source.member_id
      JOIN resource_groups AS grp ON grp.id = member.group_id
      LEFT JOIN resource_group_sets AS group_set ON group_set.id = grp.group_set_id
    """)

    execute("""
    DO $$
    DECLARE
      conflict_detail text;
    BEGIN
      SELECT string_agg(
               format(
                 'organization %s, resource %s (%s), view %s, set %s (%s), groups [%s]',
                 conflict.organization_id,
                 resource.name,
                 conflict.resource_id,
                 conflict.view,
                 group_set.name,
                 conflict.group_set_id,
                 array_to_string(conflict.group_names, ', ')
               ),
               '; '
               ORDER BY conflict.organization_id, resource.name, conflict.view, group_set.name
             )
        INTO conflict_detail
        FROM (
          SELECT membership.organization_id, membership.resource_id, membership.view,
                 membership.group_set_id, array_agg(grp.name ORDER BY grp.name) AS group_names
            FROM resource_group_memberships_backfill AS membership
            JOIN resource_groups AS grp ON grp.id = membership.group_id
           WHERE membership.group_set_id IS NOT NULL
           GROUP BY membership.organization_id, membership.resource_id, membership.view,
                    membership.group_set_id
          HAVING count(DISTINCT membership.group_id) > 1
        ) AS conflict
        JOIN resources AS resource ON resource.id = conflict.resource_id
        JOIN resource_group_sets AS group_set ON group_set.id = conflict.group_set_id;

      IF conflict_detail IS NOT NULL THEN
        RAISE EXCEPTION USING
          ERRCODE = 'integrity_constraint_violation',
          MESSAGE = 'cannot backfill inherited group memberships: ' || conflict_detail;
      END IF;
    END
    $$
    """)

    execute("DELETE FROM resource_group_memberships")

    execute("""
    INSERT INTO resource_group_memberships
      (organization_id, resource_id, view, group_id, group_set_id)
    SELECT organization_id, resource_id, view, group_id, group_set_id
      FROM resource_group_memberships_backfill
    """)
  end

  def down do
    execute("DELETE FROM resource_group_memberships")

    execute("""
    INSERT INTO resource_group_memberships
      (organization_id, resource_id, view, group_id, group_set_id)
    SELECT member.organization_id, member.resource_id, view.view, member.group_id,
           CASE WHEN group_set.exclusive THEN group_set.id END
      FROM resource_group_members AS member
      JOIN resource_groups AS grp ON grp.id = member.group_id
      LEFT JOIN resource_group_sets AS group_set ON group_set.id = grp.group_set_id
     CROSS JOIN (VALUES ('inventory'), ('trusted')) AS view(view)
    """)
  end
end
