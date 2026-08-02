defmodule Renga.Inventory.Host do
  @moduledoc """
  Typed canonical projection for host-specific inventory.

  Keeping frequently filtered host fields out of the resource `spec` preserves
  normal PostgreSQL indexes while allowing the resource envelope to serve every
  independently managed inventory kind.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "hosts" do
    field :hostname, :string
    field :fqdn, :string
    field :vendor, :string
    field :model, :string
    field :asset_tag, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :resource, Resource

    timestamps()
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:hostname, :fqdn, :vendor, :model, :asset_tag, :metadata])
    |> update_change(:hostname, &normalize_hostname/1)
    |> update_change(:fqdn, &normalize_hostname/1)
    |> validate_required([:organization_id, :resource_id])
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource)
    |> unique_constraint([:organization_id, :resource_id])
  end

  defp normalize_hostname(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_hostname(value), do: value
end
