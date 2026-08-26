defmodule Renga.Repo.Migrations.AddModuleCompatibilityFindings do
  use Ecto.Migration

  @original_kinds """
  'ambiguous_component_identity', 'ambiguous_expected_component',
  'unexpected_actual_component', 'component_drift', 'missing_expected_component'
  """

  @module_kinds """
  'module_bay_not_found', 'ambiguous_module_bay', 'module_type_not_found',
  'ambiguous_module_type', 'incompatible_module_type'
  """

  def up do
    replace_kind_constraint("#{@original_kinds}, #{@module_kinds}")
  end

  def down do
    execute("DELETE FROM component_findings WHERE kind IN (#{@module_kinds})")
    replace_kind_constraint(@original_kinds)
  end

  defp replace_kind_constraint(kinds) do
    drop constraint(:component_findings, :component_findings_valid_kind)

    create constraint(:component_findings, :component_findings_valid_kind,
             check: "kind IN (#{kinds})"
           )
  end
end
