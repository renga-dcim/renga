defmodule Renga.Telemetry do
  @moduledoc """
  Timed readings delivered apart from inventory (RFD 10, "Measured history").

  A telemetry batch is accepted once per source and replay ID, so an agent
  may resend one until it hears back. Accepting a batch writes only reading
  state: it never stores an observation, renews a lease, advances an
  inventory clock, changes snapshot completeness, or triggers
  reconciliation. An installation must have checked in before its
  telemetry is accepted.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.IntakeApiKey
  alias Renga.Power.Correlation
  alias Renga.Power.Readings
  alias Renga.Repo
  alias Renga.Telemetry.Batch
  alias Renga.Telemetry.Store

  # An agent drops a queued telemetry batch after a day, so a replay ID kept
  # for a week outlives every redelivery of its batch.
  @replay_retention_seconds 7 * 86_400
  @prune_batch 10_000

  @doc """
  Accepts a validated batch (see `Renga.Telemetry.Payload.validate/1`) from
  an installation. Returns `{:ok, batch, :created, results}`, or
  `{:ok, batch, :duplicate, nil}` when the source already accepted this
  replay ID with the same payload.
  """
  def accept_batch(%Scope{} = scope, %IntakeApiKey{} = intake_api_key, installation_id, attrs) do
    now = Renga.Time.utc_now_ms()

    scope
    |> Inventory.with_intake_source(intake_api_key, installation_id, attrs.collector, fn source ->
      case get_batch(source, attrs.replay_id) do
        %Batch{payload_digest: digest} = batch when digest == attrs.payload_digest ->
          {:ok, {batch, :duplicate, nil}}

        %Batch{} = batch ->
          {:error, {:replay_conflict, batch}}

        nil ->
          batch =
            Repo.insert!(%Batch{
              organization_id: source.organization_id,
              source_id: source.id,
              replay_id: attrs.replay_id,
              version: attrs.version,
              payload_digest: attrs.payload_digest,
              sample_count: length(attrs.samples),
              received_at: now
            })

          results = Readings.record!(source, attrs.samples, now)
          Correlation.record!(source, attrs.samples, now)
          {:ok, {batch, :created, results}}
      end
    end)
    |> case do
      {:ok, {batch, disposition, results}} -> {:ok, batch, disposition, results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_batch(source, replay_id) do
    Batch
    |> where([batch], batch.organization_id == ^source.organization_id)
    |> where([batch], batch.source_id == ^source.id and batch.replay_id == ^replay_id)
    |> Repo.one()
  end

  @doc """
  Drops what telemetry keeps past its retention at `now`: replay IDs older
  than a week, and history past the store's enforced retention. Returns how
  many of each were deleted.
  """
  def prune(now \\ Renga.Time.utc_now_ms()) do
    adapter = Store.adapter!()

    %{
      batches: prune_batches(DateTime.add(now, -@replay_retention_seconds, :second), 0),
      history: if(function_exported?(adapter, :prune, 1), do: adapter.prune(now), else: 0)
    }
  end

  defp prune_batches(before, total) do
    {:ok, deleted} =
      Repo.with_statement_timeout(Repo.background_statement_timeout_ms(), fn query_options ->
        %{num_rows: deleted} =
          Repo.query!(
            """
            DELETE FROM telemetry_batches
            WHERE id IN (SELECT id FROM telemetry_batches WHERE received_at < $1 LIMIT $2)
            """,
            [DateTime.to_naive(before), @prune_batch],
            query_options
          )

        deleted
      end)

    if deleted == @prune_batch,
      do: prune_batches(before, total + deleted),
      else: total + deleted
  end
end
