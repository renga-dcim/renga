defmodule Renga.Repo.Migrations.CreatePowerPortsAndOutlets do
  use Ecto.Migration

  # RFD 10 phase 2: typed power endpoints on a device, created from its
  # hardware type's `power_port` and `power_outlet` templates. A port is
  # where power comes in (a server's supply, a PDU's inlet); an outlet is
  # where it goes out. Allocated draw defaults from the template and an
  # operator may override it per port.
  def up do
    create table(:power_ports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_ports_organization_resource_fkey
          ),
          null: false

      add :name, :string, null: false
      add :label, :string
      add :connector, :text
      add :maximum_draw_w, :integer
      add :default_allocated_draw_w, :integer
      add :allocated_draw_w, :integer

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:power_ports, [:organization_id, :resource_id, :name])
    create unique_index(:power_ports, [:id, :organization_id])
    create unique_index(:power_ports, [:id, :organization_id, :resource_id])

    create constraint(:power_ports, :power_ports_draws,
             check: """
             (maximum_draw_w IS NULL OR maximum_draw_w > 0)
             AND (default_allocated_draw_w IS NULL OR default_allocated_draw_w > 0)
             AND (allocated_draw_w IS NULL OR allocated_draw_w > 0)
             """
           )

    create table(:power_outlets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :power_outlets_organization_resource_fkey
          ),
          null: false

      # The inlet on the same device that feeds this outlet.
      add :inlet_port_id,
          references(:power_ports,
            with: [organization_id: :organization_id, resource_id: :resource_id],
            on_delete: {:nilify, [:inlet_port_id]},
            type: :binary_id,
            name: :power_outlets_device_inlet_fkey
          )

      add :name, :string, null: false
      add :label, :string
      add :connector, :text
      add :feed_leg, :string

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:power_outlets, [:organization_id, :resource_id, :name])
    create unique_index(:power_outlets, [:id, :organization_id])

    create constraint(:power_outlets, :power_outlets_feed_leg,
             check: "feed_leg IS NULL OR feed_leg IN ('a', 'b', 'c')"
           )

    flush()

    # Existing assets get the endpoints their hardware type already expects.
    Enum.each(backfill_statements(), &execute/1)
  end

  @doc false
  # Public so the backfill can be tested against current data.
  def backfill_statements do
    [
      """
      INSERT INTO power_ports (id, organization_id, resource_id, name, label, connector,
                               maximum_draw_w, default_allocated_draw_w, inserted_at, updated_at)
      SELECT gen_random_uuid(), expected.organization_id, assignment.resource_id, expected.name,
             expected.label, #{text("connector")},
             #{watts("maximum_draw_w")}, #{watts("allocated_draw_w")}, now(), now()
      FROM expected_components AS expected
      JOIN hardware_assignments AS assignment ON assignment.id = expected.hardware_assignment_id
      WHERE expected.kind = 'power_port' AND NOT expected.suppressed
      ON CONFLICT DO NOTHING
      """,
      """
      INSERT INTO power_outlets (id, organization_id, resource_id, inlet_port_id, name, label,
                                 connector, feed_leg, inserted_at, updated_at)
      SELECT gen_random_uuid(), expected.organization_id, assignment.resource_id, inlet.id,
             expected.name, expected.label, #{text("connector")},
             CASE WHEN jsonb_typeof(expected.attributes->'feed_leg') = 'string'
                        AND lower(#{trimmed("feed_leg")}) IN ('a', 'b', 'c')
                  THEN lower(#{trimmed("feed_leg")}) END,
             now(), now()
      FROM expected_components AS expected
      JOIN hardware_assignments AS assignment ON assignment.id = expected.hardware_assignment_id
      LEFT JOIN power_ports AS inlet
        ON inlet.organization_id = expected.organization_id
       AND inlet.resource_id = assignment.resource_id
       AND inlet.name = #{text("inlet")}
      WHERE expected.kind = 'power_outlet' AND NOT expected.suppressed
      ON CONFLICT DO NOTHING
      """
    ]
  end

  def down do
    drop table(:power_outlets)
    drop table(:power_ports)
  end

  # A positive whole number of watts small enough for an integer, or NULL.
  defp watts(key) do
    value = trimmed(key)
    significant = "ltrim(ltrim(#{value}, '+'), '0')"

    """
    CASE WHEN jsonb_typeof(expected.attributes->'#{key}') IN ('number', 'string')
              AND #{value} ~ '^\\+?[0-9]+$'
         THEN CASE WHEN length(#{significant}) BETWEEN 1 AND 9
                   THEN (#{significant})::integer END
         END
    """
  end

  # Only JSON strings are text attributes; JSON numbers and booleans stay unset.
  defp text(key) do
    """
    CASE WHEN jsonb_typeof(expected.attributes->'#{key}') = 'string'
         THEN NULLIF(#{trimmed(key)}, '') END
    """
  end

  # PostgreSQL's one-argument btrim removes only spaces. This explicit set is
  # Unicode White_Space, which is what Elixir's String.trim/1 removes.
  defp trimmed(key) do
    "btrim(expected.attributes->>'#{key}', " <>
      "U&'\\0009\\000A\\000B\\000C\\000D\\0020\\0085\\00A0\\1680" <>
      "\\2000\\2001\\2002\\2003\\2004\\2005\\2006\\2007\\2008\\2009\\200A" <>
      "\\2028\\2029\\202F\\205F\\3000')"
  end
end
