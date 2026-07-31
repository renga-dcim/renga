defmodule Renga.Inventory.Source do
  @moduledoc """
  A source is an organization-scoped producer of inventory observations.

  Sources are the provenance anchor for host agents, switch collectors, VM
  syncers, and future integrations. Resource facts should point back to the
  source that reported them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Address
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.SyncRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(host_agent switch_poller vm_provider bmc manual)
  @statuses ~w(active revoked disabled)
  @timestamps_opts [type: :utc_datetime]

  schema "sources" do
    field :kind, :string
    field :name, :string
    field :status, :string, default: "active"
    field :token_hash, :binary
    field :capabilities, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    has_many :addresses, Address
    has_many :change_events, ChangeEvent
    has_many :interfaces, Interface
    has_many :observations, Observation
    has_many :resource_identifiers, ResourceIdentifier
    has_many :sync_runs, SyncRun

    timestamps()
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:kind, :name, :status, :capabilities, :last_seen_at, :metadata],
      empty_values: []
    )
    |> validate_required([:organization_id, :kind, :name, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_capabilities()
    |> assoc_constraint(:organization)
    |> unique_constraint([:organization_id, :name])
  end

  @doc """
  Changes only the token authentication material for a source.

  Keeping this separate from the public changeset prevents caller-controlled
  attrs from setting token hashes directly.
  """
  def token_changeset(source, token_hash) when is_binary(token_hash) do
    source
    |> change(token_hash: token_hash, status: "active")
    |> unique_constraint(:token_hash)
  end

  @doc """
  Disables token authentication while retaining the source row for provenance.
  """
  def revoke_changeset(source) do
    change(source, token_hash: nil, status: "revoked")
  end

  defp validate_capabilities(changeset) do
    validate_change(changeset, :capabilities, fn :capabilities, capabilities ->
      if Enum.all?(capabilities, &valid_capability?/1) do
        []
      else
        [capabilities: "must contain only non-empty strings"]
      end
    end)
  end

  defp valid_capability?(capability) when is_binary(capability) do
    String.trim(capability) != ""
  end

  defp valid_capability?(_capability), do: false
end
