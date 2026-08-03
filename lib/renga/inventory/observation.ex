defmodule Renga.Inventory.Observation do
  @moduledoc """
  Immutable raw inventory payload accepted from one source.

  This row records what the source said and when. Matching decisions, attempts,
  status, and errors belong to `Renga.Inventory.ObservationReconciliation` so a
  retry or improved reconciler cannot rewrite historical evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.ResourceIdentifierClaim
  alias Renga.Inventory.Source
  alias Renga.Inventory.SyncRun

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "observations" do
    field :idempotency_key, :string
    field :observed_at, :utc_datetime_usec
    field :payload_digest, :binary
    field :payload, :map

    belongs_to :organization, Organization
    belongs_to :source, Source
    belongs_to :sync_run, SyncRun
    has_many :reconciliations, ObservationReconciliation
    has_many :resource_identifier_claims, ResourceIdentifierClaim
    has_many :change_events, ChangeEvent

    timestamps(updated_at: false)
  end

  def changeset(observation, attrs) do
    observation
    |> cast(attrs, [:idempotency_key, :observed_at, :payload_digest, :payload])
    |> reject_mutation()
    |> put_uuidv7_identity()
    |> update_change(:idempotency_key, &trim_string/1)
    |> validate_required([
      :organization_id,
      :source_id,
      :idempotency_key,
      :observed_at,
      :payload_digest,
      :payload
    ])
    |> assoc_constraint(:organization)
    |> assoc_constraint(:source)
    |> assoc_constraint(:sync_run)
    |> unique_constraint([:organization_id, :source_id, :idempotency_key])
  end

  defp reject_mutation(%Ecto.Changeset{data: %{id: id}, changes: changes} = changeset)
       when not is_nil(id) and map_size(changes) > 0 do
    add_error(changeset, :base, "observation is immutable")
  end

  defp reject_mutation(changeset), do: changeset

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
