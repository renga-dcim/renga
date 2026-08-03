defmodule Renga.Inventory.Resource do
  @moduledoc """
  Organization-scoped envelope for an independently addressable object.

  The envelope carries desired state and control-plane metadata. Stable domain
  facts belong in typed projections such as `Renga.Inventory.Host` and
  `Renga.Inventory.Interface`; source evidence and raw observations remain
  separate so canonical state never loses provenance.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Address
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Host
  alias Renga.Inventory.Interface
  alias Renga.Inventory.ResourceCondition
  alias Renga.Inventory.ResourceIdentifier
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.ResourceOverride
  alias Renga.Inventory.ResourceRevision

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(server switch vm container pdu storage prefix vlan vrf unknown)
  @lifecycle_states ~w(active inactive retired unknown)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resources" do
    field :kind, :string
    field :name, :string
    field :display_name, :string
    field :lifecycle_state, :string, default: "unknown"
    field :spec, :map, default: %{}
    field :generation, :integer, default: 1
    field :resource_version, :integer
    field :labels, :map, default: %{}
    field :annotations, :map, default: %{}
    field :deletion_requested_at, :utc_datetime_usec

    belongs_to :organization, Organization
    has_one :host, Host
    has_many :addresses, Address
    has_many :change_events, ChangeEvent
    has_many :conditions, ResourceCondition
    has_many :identifiers, ResourceIdentifier
    has_many :identifier_claims, ResourceIdentifierClaim
    has_many :interfaces, Interface
    has_many :overrides, ResourceOverride
    has_many :revisions, ResourceRevision

    timestamps()
  end

  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [
      :kind,
      :name,
      :display_name,
      :lifecycle_state,
      :spec,
      :labels,
      :annotations,
      :deletion_requested_at
    ])
    |> update_change(:name, &String.trim/1)
    |> update_change(:display_name, &trim_string/1)
    |> maybe_increment_generation()
    |> validate_required([:organization_id, :kind, :name, :lifecycle_state])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:lifecycle_state, @lifecycle_states)
    |> validate_number(:generation, greater_than: 0)
    |> validate_map(:spec)
    |> validate_map(:labels)
    |> validate_map(:annotations)
    |> assoc_constraint(:organization)
    |> unique_constraint([:organization_id, :kind, :name])
  end

  # Generation changes only when desired state changes, not for labels, status,
  # conditions, or observations. Controllers can use it as a reconciliation fence.
  defp maybe_increment_generation(%Ecto.Changeset{data: %{id: nil}} = changeset), do: changeset

  defp maybe_increment_generation(changeset) do
    if get_change(changeset, :spec) do
      put_change(changeset, :generation, changeset.data.generation + 1)
    else
      changeset
    end
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
