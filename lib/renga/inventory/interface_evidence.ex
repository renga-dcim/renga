defmodule Renga.Inventory.InterfaceEvidence do
  @moduledoc """
  Observation-scoped source evidence for a canonical interface.

  The typed observed fields make source comparison queryable without assigning
  canonical ownership to whichever collector reported the interface first.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Interface
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Source
  alias Renga.Types.MacAddress

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(ethernet loopback bond bridge vlan virtual unknown)
  @statuses ~w(up down dormant not_present unknown)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "interface_evidence" do
    field :name, :string
    field :mac_address, MacAddress
    field :kind, :string
    field :status, :string
    field :mtu, :integer
    field :speed_mbps, :integer
    field :metadata, :map, default: %{}
    field :observed_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :interface, Interface
    belongs_to :source, Source
    belongs_to :observation, Observation

    timestamps()
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :name,
      :mac_address,
      :kind,
      :status,
      :mtu,
      :speed_mbps,
      :metadata,
      :observed_at
    ])
    |> validate_required([
      :organization_id,
      :interface_id,
      :source_id,
      :observation_id,
      :name,
      :kind,
      :status,
      :observed_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:mtu, greater_than: 0)
    |> validate_number(:speed_mbps, greater_than: 0)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:interface)
    |> assoc_constraint(:source)
    |> assoc_constraint(:observation)
    |> unique_constraint([:organization_id, :observation_id, :interface_id],
      name: :interface_evidence_observation_link_index
    )
  end
end
