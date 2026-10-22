defmodule Renga.DeploymentAudit.Event do
  @moduledoc """
  One attempted operator mutation in the deployment audit log (RFD 22).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "deployment_audit_events" do
    field :operation, :string
    field :outcome, :string
    field :actor, :string
    field :actor_token_id, :binary_id
    field :invocation_id, :string
    field :target_id, :string
    field :organization_id, :binary_id
    field :organization_name, :string
    field :changed, {:array, :string}, default: []
    field :reason, :string

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end
end
