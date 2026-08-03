defmodule Renga.Inventory.Prefix do
  @moduledoc """
  Typed canonical IPAM prefix projection backed by PostgreSQL `cidr`.

  Prefix containment and overlap remain database operations rather than string
  parsing, while the associated resource envelope carries desired state.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource
  alias Renga.Types.Cidr

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(active reserved deprecated)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "prefixes" do
    field :prefix, Cidr
    field :vrf, :string
    field :status, :string, default: "active"
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource

    timestamps()
  end

  def changeset(prefix, attrs) do
    prefix
    |> cast(attrs, [:prefix, :vrf, :status, :description, :metadata])
    |> validate_required([:organization_id, :resource_id, :prefix, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> unique_constraint([:organization_id, :resource_id])
  end
end
