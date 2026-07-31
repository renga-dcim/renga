defmodule Renga.Accounts.Organization do
  @moduledoc """
  An organization is the primary tenant boundary in Renga.

  Inventory, sources, future jobs, and UI queries should all carry this id so
  multi-tenant isolation is explicit in database constraints and context calls.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Inventory.Address
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Interface
  alias Renga.Inventory.InterfaceRelationship
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceOverride
  alias Renga.Inventory.SyncRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(active disabled)
  @timestamps_opts [type: :utc_datetime]

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :settings, :map, default: %{}

    has_many :memberships, OrganizationMembership
    has_many :addresses, Address
    has_many :change_events, ChangeEvent
    has_many :interfaces, Interface
    has_many :interface_relationships, InterfaceRelationship
    has_many :observations, Observation
    has_many :resource_overrides, ResourceOverride
    has_many :resources, Resource
    has_many :sync_runs, SyncRun

    timestamps()
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug, :status, :settings])
    |> validate_required([:name, :slug, :status])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message:
        "must start with a lowercase letter or number and contain only lowercase letters, numbers, and dashes"
    )
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug)
  end
end
