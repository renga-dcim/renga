defmodule Renga.Telemetry.Store.Postgres do
  @moduledoc """
  The built-in telemetry store (`Renga.Telemetry.Store`): five-minute
  buckets in Postgres, kept for 30 days, so a self-hosted Renga needs no
  extra infrastructure.

  A write folds each sample into its bucket's count, sum, minimum, maximum,
  and last value; raw samples are not kept. Wider buckets merge those on
  read. Retention is enforced here: a sample older than 30 days, or more
  than five minutes ahead of the clock, is not written, reads never return a
  bucket past retention, and `prune/1` deletes them.
  """

  @behaviour Renga.Telemetry.Store

  alias Renga.Repo
  alias Renga.Telemetry.Store
  alias Renga.Telemetry.Store.Bucket

  @bucket_seconds 300
  @retention_seconds 30 * 86_400
  @future_seconds 300
  @prune_batch 10_000

  @impl true
  def bucket_seconds, do: @bucket_seconds

  @impl true
  def retention, do: {:enforced, @retention_seconds}

  @impl true
  def write(organization_id, samples) do
    now = Renga.Time.utc_now_ms()
    oldest = horizon(now)
    latest = DateTime.add(now, @future_seconds, :second)

    rows =
      samples
      |> Enum.filter(
        &(DateTime.compare(&1.at, oldest) != :lt and DateTime.compare(&1.at, latest) != :gt)
      )
      |> Enum.group_by(&{&1.series, Store.floor_to(&1.at, @bucket_seconds)})
      |> Enum.map(fn {{series, start}, samples} -> fold(series, start, samples) end)

    if rows != [], do: upsert!(organization_id, rows)
    :ok
  end

  defp fold(series, start, samples) do
    values = Enum.map(samples, & &1.value)
    last = Enum.max_by(samples, & &1.at, DateTime)

    %{
      series: series,
      start: start,
      count: length(values),
      sum: Enum.sum(values),
      minimum: Enum.min(values),
      maximum: Enum.max(values),
      last_value: last.value,
      last_at: last.at
    }
  end

  # One statement for the whole write; a bucket already holding samples
  # merges with the new ones, and its last value is the later sample's.
  defp upsert!(organization_id, rows) do
    Repo.query!(
      """
      INSERT INTO telemetry_buckets AS bucket
        (organization_id, series, bucket_start, count, sum, minimum, maximum, last_value, last_at)
      SELECT $1::uuid, row.*
      FROM unnest($2::text[], $3::timestamp[], $4::integer[], $5::float8[], $6::float8[],
                  $7::float8[], $8::float8[], $9::timestamp[]) AS row
      ON CONFLICT (organization_id, series, bucket_start) DO UPDATE SET
        count = bucket.count + EXCLUDED.count,
        sum = bucket.sum + EXCLUDED.sum,
        minimum = LEAST(bucket.minimum, EXCLUDED.minimum),
        maximum = GREATEST(bucket.maximum, EXCLUDED.maximum),
        last_value = CASE WHEN EXCLUDED.last_at >= bucket.last_at
                          THEN EXCLUDED.last_value ELSE bucket.last_value END,
        last_at = GREATEST(bucket.last_at, EXCLUDED.last_at)
      """,
      [
        Ecto.UUID.dump!(organization_id),
        Enum.map(rows, & &1.series),
        Enum.map(rows, &DateTime.to_naive(&1.start)),
        Enum.map(rows, & &1.count),
        Enum.map(rows, & &1.sum),
        Enum.map(rows, & &1.minimum),
        Enum.map(rows, & &1.maximum),
        Enum.map(rows, & &1.last_value),
        Enum.map(rows, &DateTime.to_naive(&1.last_at))
      ]
    )
  end

  @impl true
  def range(organization_id, series, from, to, bucket_seconds) do
    from =
      Enum.max(
        [from, Store.floor_to(horizon(Renga.Time.utc_now_ms()), @bucket_seconds)],
        DateTime
      )

    %{rows: rows} =
      Repo.query!(
        """
        SELECT series,
               to_timestamp(floor(extract(epoch FROM bucket_start) / $5) * $5) AT TIME ZONE 'UTC',
               sum(count), sum(sum), min(minimum), max(maximum),
               (array_agg(last_value ORDER BY last_at DESC))[1]
        FROM telemetry_buckets
        WHERE organization_id = $1 AND series = ANY($2)
          AND bucket_start >= $3 AND bucket_start < $4
        GROUP BY 1, 2
        ORDER BY 1, 2
        """,
        [
          Ecto.UUID.dump!(organization_id),
          series,
          DateTime.to_naive(from),
          DateTime.to_naive(to),
          bucket_seconds
        ]
      )

    buckets =
      Enum.group_by(
        rows,
        fn [series | _rest] -> series end,
        fn [_series, start, count, sum, minimum, maximum, last] ->
          %Bucket{
            start: DateTime.from_naive!(start, "Etc/UTC") |> DateTime.truncate(:second),
            count: count,
            average: sum / count,
            minimum: minimum,
            maximum: maximum,
            last: last
          }
        end
      )

    {:ok, buckets}
  end

  @impl true
  def prune(now), do: prune(Store.floor_to(horizon(now), @bucket_seconds), 0)

  # In batches, so no one delete holds its locks for long.
  defp prune(before, total) do
    {:ok, deleted} =
      Repo.with_statement_timeout(Repo.background_statement_timeout_ms(), fn query_options ->
        %{num_rows: deleted} =
          Repo.query!(
            """
            DELETE FROM telemetry_buckets
            WHERE ctid IN (
              SELECT ctid FROM telemetry_buckets WHERE bucket_start < $1 LIMIT $2
            )
            """,
            [DateTime.to_naive(before), @prune_batch],
            query_options
          )

        deleted
      end)

    if deleted == @prune_batch,
      do: prune(before, total + deleted),
      else: total + deleted
  end

  defp horizon(now), do: DateTime.add(now, -@retention_seconds, :second)
end
