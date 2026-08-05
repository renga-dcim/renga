defmodule Renga.Inventory.ResourceRevision do
  @moduledoc """
  Ordered resource mutation record used as the future list/watch boundary.

  Audit events explain user-facing changes; revisions provide a monotonic cursor
  and immutable snapshot for consumers that need ordered state delivery.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @actions ~w(created updated deletion_requested)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "resource_revisions" do
    field :revision, :integer
    field :action, :string
    field :generation, :integer
    field :snapshot, :map

    belongs_to :organization, Organization
    belongs_to :resource, Resource

    timestamps(updated_at: false)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:revision, :action, :generation, :snapshot])
    |> validate_required([
      :organization_id,
      :resource_id,
      :revision,
      :action,
      :generation,
      :snapshot
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:generation, greater_than: 0)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:resource, name: :resource_revisions_organization_resource_fkey)
    |> unique_constraint(:revision)
  end
end
