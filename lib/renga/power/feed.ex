defmodule Renga.Power.Feed do
  @moduledoc """
  One circuit from a power panel (RFD 10, "Model").

  `voltage` follows the supply: for single-phase AC it is measured across the
  supply conductors, for three-phase AC it is the line-to-line voltage, and
  for DC it is the nominal bus voltage. `amperage` is the circuit's rated
  current, never an observed load. `max_utilization` is the percentage of
  that rating that may be used, 80 by default. `side` is the redundancy side
  a device's supplies must split across.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @statuses ~w(planned active offline decommissioning)
  @supplies ~w(ac dc)
  @phases ~w(single three)
  @sides ~w(a b)

  schema "power_feeds" do
    field :name, :string
    field :status, :string, default: "active"
    field :supply, :string, default: "ac"
    field :phase, :string, default: "single"
    field :voltage, :decimal
    field :amperage, :decimal
    field :max_utilization, :integer, default: 80
    field :side, :string
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :site, Renga.DCIM.Site
    belongs_to :panel, Renga.Power.Panel
    belongs_to :rack, Renga.DCIM.Rack

    timestamps()
  end

  def statuses, do: @statuses
  def supplies, do: @supplies
  def phases, do: @phases
  def sides, do: @sides

  @doc """
  Casts operator input. The panel, and with it the site, is set by the
  context, never cast.
  """
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :rack_id,
      :name,
      :status,
      :supply,
      :phase,
      :voltage,
      :amperage,
      :max_utilization,
      :side,
      :description,
      :metadata
    ])
    |> update_change(:name, &String.trim/1)
    |> clear_dc_phase()
    |> validate_required([
      :organization_id,
      :resource_id,
      :site_id,
      :panel_id,
      :name,
      :status,
      :supply,
      :voltage,
      :amperage,
      :max_utilization
    ])
    |> validate_length(:name, max: 255, count: :codepoints)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:supply, @supplies)
    |> validate_inclusion(:side, @sides)
    |> validate_ac_phase()
    |> validate_number(:voltage, greater_than: 0)
    |> validate_number(:amperage, greater_than: 0)
    |> validate_number(:max_utilization, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> check_constraint(:supply, name: :power_feeds_electrical)
    |> assoc_constraint(:resource, name: :power_feeds_organization_resource_fkey)
    |> assoc_constraint(:panel, name: :power_feeds_site_panel_fkey)
    |> assoc_constraint(:rack,
      name: :power_feeds_site_rack_fkey,
      message: "must be a rack at the panel's site"
    )
    |> unique_constraint(:name,
      name: :power_feeds_organization_id_panel_id_name_index,
      message: "is already used by a feed on this panel"
    )
  end

  # A DC feed has no phase, so one left over from switching supply is dropped.
  defp clear_dc_phase(changeset) do
    if get_field(changeset, :supply) == "dc",
      do: put_change(changeset, :phase, nil),
      else: changeset
  end

  defp validate_ac_phase(changeset) do
    if get_field(changeset, :supply) == "ac" do
      changeset
      |> validate_required([:phase], message: "is required for AC")
      |> validate_inclusion(:phase, @phases)
    else
      changeset
    end
  end
end
