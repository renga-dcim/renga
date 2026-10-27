defmodule RengaWeb.Operator.V1.Schemas.LifecycleState do
  @moduledoc false

  def json_schema do
    RengaWeb.Operator.V1.Schemas.Organization.json_schema()
    |> Map.put(:title, "OrganizationLifecycleState")
    |> Map.put(:description, "Committed lifecycle state; no tenant inventory or memberships.")
    |> Map.update!(:properties, &Map.delete(&1, :members))
    |> Map.put(:required, [:id, :name, :slug, :status, :deletion_scheduled_at, :deletion_due_at])
  end
end
