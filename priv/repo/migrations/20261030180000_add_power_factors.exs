defmodule Renga.Repo.Migrations.AddPowerFactors do
  use Ecto.Migration

  # RFD 10 phase 3: turning allocated watts into volt-amperes needs a power
  # factor with provenance. A port takes one from its hardware type's template
  # or an operator's override; an owner may set an organization-wide default.
  # None is assumed, so nothing is filled in beyond what templates state.

  def up do
    alter table(:organizations) do
      add :default_power_factor, :decimal, precision: 4, scale: 3
    end

    create constraint(:organizations, :organizations_default_power_factor,
             check: valid(:default_power_factor)
           )

    alter table(:power_ports) do
      add :default_power_factor, :decimal, precision: 4, scale: 3
      add :power_factor, :decimal, precision: 4, scale: 3
    end

    create constraint(:power_ports, :power_ports_power_factors,
             check: "(#{valid(:default_power_factor)}) AND (#{valid(:power_factor)})"
           )

    Enum.each(backfill_statements(), &execute/1)
  end

  def down do
    alter table(:power_ports) do
      remove :power_factor
      remove :default_power_factor
    end

    alter table(:organizations) do
      remove :default_power_factor
    end
  end

  @doc false
  # Public so the backfill can be tested against current data. Ports that
  # already exist take their template's power factor, parsed as
  # `Renga.Power.PowerFactor.parse/1` does.
  def backfill_statements do
    [
      """
      UPDATE power_ports AS port
      SET default_power_factor = #{power_factor("power_factor")}
      FROM expected_components AS expected
      JOIN hardware_assignments AS assignment ON assignment.id = expected.hardware_assignment_id
      WHERE expected.kind = 'power_port' AND NOT expected.suppressed
        AND port.organization_id = expected.organization_id
        AND port.resource_id = assignment.resource_id
        AND port.name = expected.name
      """
    ]
  end

  defp valid(column), do: "#{column} IS NULL OR (#{column} > 0 AND #{column} <= 1)"

  # A plain decimal above 0 and at most 1 with at most three significant
  # decimal places, or NULL. The nested CASE keeps the cast behind the match.
  defp power_factor(key) do
    value = trimmed(key)

    """
    CASE WHEN jsonb_typeof(expected.attributes->'#{key}') IN ('number', 'string')
              AND #{value} ~ '^[0-9]{1,16}(\\.[0-9]{1,16})?$'
         THEN CASE WHEN (#{value})::numeric > 0 AND (#{value})::numeric <= 1
                        AND round((#{value})::numeric, 3) = (#{value})::numeric
                   THEN round((#{value})::numeric, 3) END
         END
    """
  end

  # Unicode White_Space, which is what Elixir's String.trim/1 removes.
  defp trimmed(key) do
    "btrim(expected.attributes->>'#{key}', " <>
      "U&'\\0009\\000A\\000B\\000C\\000D\\0020\\0085\\00A0\\1680" <>
      "\\2000\\2001\\2002\\2003\\2004\\2005\\2006\\2007\\2008\\2009\\200A" <>
      "\\2028\\2029\\202F\\205F\\3000')"
  end
end
