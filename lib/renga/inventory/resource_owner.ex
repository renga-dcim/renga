defmodule Renga.Inventory.ResourceOwner do
  @moduledoc """
  Lifecycle ownership from one resource envelope to a managed child.

  Ownership is distinct from topology: deleting a lifecycle owner may later
  drive child cleanup, while a topology link carries no deletion semantics.
  Finalizers are intentionally deferred until destructive workflows exist.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(agent_managed libvirt_domain cloud_hypervisor component)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_owners" do
    field :kind, :string
    field :controller, :boolean, default: true
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :owner_resource, Resource
    belongs_to :child_resource, Resource

    timestamps()
  end

  def changeset(owner, attrs) do
    owner
    |> cast(attrs, [:kind, :controller, :metadata])
    |> validate_required([:organization_id, :owner_resource_id, :child_resource_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_distinct_resources()
    |> check_constraint(:child_resource_id, name: :resource_owners_distinct_endpoints)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:owner_resource, name: :resource_owners_tenant_owner_fkey)
    |> assoc_constraint(:child_resource, name: :resource_owners_tenant_child_fkey)
    |> unique_constraint(
      [:organization_id, :owner_resource_id, :child_resource_id, :kind],
      name: :resource_owners_owner_child_kind_index
    )
    |> unique_constraint([:organization_id, :child_resource_id],
      name: :resource_owners_child_controller_index
    )
  end

  defp validate_distinct_resources(changeset) do
    if get_field(changeset, :owner_resource_id) == get_field(changeset, :child_resource_id) do
      add_error(changeset, :child_resource_id, "must be different from owner resource")
    else
      changeset
    end
  end
end
