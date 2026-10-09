defmodule Renga.Catalog.TemplatePattern.Group do
  @moduledoc """
  Component templates that share kind, requirement, label, description,
  and attributes, named by one pattern (`Renga.Catalog.TemplatePattern`).
  `position_pattern` is nil when the templates name no position.
  """
  defstruct [
    :kind,
    :name_pattern,
    :position_pattern,
    :label,
    :description,
    required: true,
    attributes: %{},
    templates: []
  ]
end
