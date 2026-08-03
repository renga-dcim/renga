defmodule Renga.Inventory.AgentLease do
  @moduledoc """
  Renewable liveness record for one registered agent.

  Lease expiry answers whether the process is connected. It does not determine
  whether the agent's last inventory observation is current.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "agent_leases" do
    field :renewed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :agent, Agent

    timestamps()
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [:renewed_at, :expires_at])
    |> validate_required([:organization_id, :agent_id, :renewed_at, :expires_at])
    |> validate_expiry()
    |> assoc_constraint(:organization)
    |> assoc_constraint(:agent)
    |> unique_constraint([:organization_id, :agent_id])
  end

  @doc """
  Returns true once the lease expiration is at or before the comparison time.
  """
  def expired?(%__MODULE__{expires_at: expires_at}, now \\ Renga.Time.utc_now_ms()) do
    DateTime.compare(expires_at, now) in [:lt, :eq]
  end

  defp validate_expiry(changeset) do
    renewed_at = get_field(changeset, :renewed_at)
    expires_at = get_field(changeset, :expires_at)

    if renewed_at && expires_at && DateTime.compare(expires_at, renewed_at) != :gt do
      add_error(changeset, :expires_at, "must be after renewed_at")
    else
      changeset
    end
  end
end
