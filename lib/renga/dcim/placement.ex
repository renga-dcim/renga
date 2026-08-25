defmodule Renga.DCIM.Placement do
  @moduledoc "Shared schema contract for desired and reconciled current placement."

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)

    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

      schema unquote(table) do
        field :position, :integer
        field :height_units, :integer
        field :face, :string
        field :confirmed, :boolean, default: false
        field :provenance, :map, default: %{}
        field :evidence_observed_at, :utc_datetime_usec, virtual: true
        field :evidence_stale?, :boolean, virtual: true
        belongs_to :organization, Renga.Accounts.Organization
        belongs_to :resource, Renga.Inventory.Resource
        belongs_to :site, Renga.DCIM.Site
        belongs_to :location, Renga.DCIM.Location
        belongs_to :rack, Renga.DCIM.Rack
        timestamps()
      end

      def changeset(placement, attrs) do
        placement
        |> cast(attrs, [
          :site_id,
          :location_id,
          :rack_id,
          :position,
          :height_units,
          :face,
          :confirmed,
          :provenance
        ])
        |> validate_required([:organization_id, :resource_id, :site_id])
        |> validate_inclusion(:face, ~w(front rear full), allow_nil: true)
        |> validate_number(:position, greater_than: 0)
        |> validate_number(:height_units, greater_than: 0)
        |> check_constraint(:position, name: unquote(:"#{table}_valid_rack_position"))
        |> assoc_constraint(:resource, name: unquote(:"#{table}_resource_fkey"))
        |> assoc_constraint(:site, name: unquote(:"#{table}_site_fkey"))
        |> assoc_constraint(:location, name: unquote(:"#{table}_location_fkey"))
        |> assoc_constraint(:rack, name: unquote(:"#{table}_rack_fkey"))
        |> unique_constraint([:organization_id, :resource_id])
      end
    end
  end
end
