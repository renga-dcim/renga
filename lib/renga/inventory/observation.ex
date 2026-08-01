defmodule Renga.Inventory.Observation do
  @moduledoc """
  Immutable raw inventory payload observed by a source.

  Observations keep the source payload and digest separate from canonical
  resources so reconciliation decisions can be re-run or audited later.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.Resource
  alias Renga.Inventory.Source
  alias Renga.Inventory.SyncRun

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type :binary_id
  @statuses ~w(accepted rejected reconciled failed)
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "observations" do
    field :observation_id, :string
    field :observed_at, :utc_datetime_usec
    field :status, :string, default: "accepted"
    field :payload_digest, :binary
    field :payload, :map
    field :errors, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization
    belongs_to :source, Source
    belongs_to :sync_run, SyncRun
    belongs_to :resource, Resource
    has_many :change_events, ChangeEvent

    timestamps(updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :observation_id,
      :observed_at,
      :status,
      :payload_digest,
      :payload,
      :errors,
      :metadata
    ])
    |> put_uuidv7_identity()
    |> update_change(:observation_id, &trim_string/1)
    |> validate_required([:organization_id, :observed_at, :status, :payload_digest, :payload])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source)
    |> assoc_constraint(:sync_run)
    |> assoc_constraint(:resource)
    |> unique_constraint([:organization_id, :source_id, :observation_id])
    |> unique_constraint([:organization_id, :source_id, :payload_digest])
  end

  defp put_uuidv7_identity(changeset) do
    if get_field(changeset, :id) do
      changeset
    else
      {id, inserted_at} = generate_uuidv7_identity()

      changeset
      |> put_change(:id, id)
      |> put_change(:inserted_at, inserted_at)
    end
  end

  defp generate_uuidv7_identity do
    id = Ecto.UUID.generate(version: 7, precision: :monotonic)
    # Keep immutable row storage time aligned with the UUIDv7 creation timestamp.
    {:ok, <<unix_ms::48, _rest::binary>>} = Ecto.UUID.dump(id)
    {id, Renga.Time.from_unix_ms!(unix_ms)}
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
