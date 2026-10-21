defmodule Renga.Jobs.TargetBinding do
  @moduledoc """
  An owner or admin's statement that one resource is reached through one
  installation holding one approved key (RFD 13, "Trusted privileged
  targets").

  Inventory reports never create or move a binding: anyone with the intake
  key can claim to report a resource, so only this approval decides where a
  privileged job may run. Each new binding for a resource gets the next
  version; privileged jobs record the version they were requested under and
  fail rather than follow a changed binding.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "target_bindings" do
    field :version, :integer
    field :status, :string, default: "active"
    field :approved_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :revoked_reason, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :agent, Renga.Inventory.Agent
    belongs_to :installation_key, Renga.Inventory.InstallationKey
    belongs_to :approved_by_user, Renga.Accounts.User
    belongs_to :revoked_by_user, Renga.Accounts.User

    timestamps()
  end
end
