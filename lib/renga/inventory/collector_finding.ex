defmodule Renga.Inventory.CollectorFinding do
  @moduledoc """
  Something Renga noticed about an installation, filed on the resource it
  reports so it reaches the Inbox (RFD 8):

    * `installation_key_changed` (RFD 13): the installation presented a key
      other than the one an owner or admin approved.
    * `possible_same_machine` (RFD 11): the host the installation reports has
      no usable SMBIOS UUID, and its MAC addresses cover exactly one fresh
      libvirt domain. MACs alone never merge machines, so a person decides.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]
  @kinds ~w(installation_key_changed possible_same_machine)

  schema "collector_findings" do
    field :kind, :string
    field :status, :string, default: "open"
    field :message, :string
    field :details, :map, default: %{}
    field :last_observed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :resource, Renga.Inventory.Resource
    belongs_to :agent, Renga.Inventory.Agent

    timestamps()
  end

  def kinds, do: @kinds
end
