defmodule Renga.Telemetry.Store do
  @moduledoc """
  Measured history (RFD 10, "Measured history"): an organization's numeric
  samples, read back over a time range in fixed buckets.

  Every bucket of a range read gives the average, minimum, maximum, and last
  value of its samples, and their count. A bucket without samples is a gap
  (`Renga.Telemetry.Store.Bucket.gap?/1`), never interpolated and never
  zero. The store only feeds charts and trends: current-reading eligibility,
  findings, and capacity never read it, so swapping adapters or losing the
  store changes none of them. It is not specific to power.

  The adapter is configured as

      config :renga, Renga.Telemetry.Store, adapter: Renga.Telemetry.Store.Postgres

  and defaults to the built-in `Renga.Telemetry.Store.Postgres`, which keeps
  five-minute buckets for 30 days and enforces that retention itself.

  ## Adapters

  An adapter implements this behaviour's callbacks, and must provide both
  sides: writes and tenant-scoped range reads. A write-only transport, such
  as Prometheus or VictoriaMetrics remote write without a PromQL-compatible
  read path, is incomplete, and the application refuses to start with one.
  Every call carries the organization, and an external adapter must isolate
  it in its backend namespace and in every query.

  An adapter may leave empty buckets out of a range read: this module fills
  them in as gaps. Retention and downsampling in an external backend are the
  operator's policy, which the adapter reports from `c:retention/0` rather
  than enforcing.
  """

  alias Renga.Accounts.Scope
  alias Renga.Telemetry.Store.Bucket

  @typedoc "Names one series within an organization, such as `power/feed/<id>/apparent_power`."
  @type series :: String.t()

  @type sample :: %{series: series(), at: DateTime.t(), value: float()}

  @typedoc """
  How long history is kept: enforced by the adapter for a number of seconds,
  or managed by the backend's operator, described in a sentence.
  """
  @type retention :: {:enforced, pos_integer()} | {:managed, String.t()}

  @doc "Records `samples` for the organization."
  @callback write(organization_id :: Ecto.UUID.t(), samples :: [sample()]) ::
              :ok | {:error, term()}

  @doc """
  Reads the organization's `series` from `from` (inclusive) to `to`
  (exclusive) in buckets `bucket_seconds` wide, both aligned to that width.
  Returns the non-empty buckets of each series, oldest first.
  """
  @callback range(
              organization_id :: Ecto.UUID.t(),
              series :: [series()],
              from :: DateTime.t(),
              to :: DateTime.t(),
              bucket_seconds :: pos_integer()
            ) :: {:ok, %{series() => [Bucket.t()]}} | {:error, term()}

  @doc "The narrowest bucket the adapter keeps, in seconds; range buckets are multiples of it."
  @callback bucket_seconds() :: pos_integer()

  @callback retention() :: retention()

  @doc "Drops history past the adapter's enforced retention, for a store that enforces one."
  @callback prune(now :: DateTime.t()) :: non_neg_integer()

  @optional_callbacks prune: 1

  @series_max 255
  @max_buckets 2_016
  # Every series gets every bucket, so this bounds a read's whole result.
  @max_points 20_160

  @doc """
  The configured adapter. Raises unless it provides both writes and range
  reads, so a write-only store never starts.
  """
  def adapter! do
    adapter =
      :renga
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:adapter, Renga.Telemetry.Store.Postgres)

    validate!(adapter)
  end

  @doc false
  def validate!(adapter) do
    Code.ensure_loaded(adapter)

    missing =
      for {name, arity} <- [write: 2, range: 5, bucket_seconds: 0, retention: 0],
          not function_exported?(adapter, name, arity),
          do: "#{name}/#{arity}"

    if missing != [] do
      raise ArgumentError,
            "telemetry store adapter #{inspect(adapter)} does not implement " <>
              Enum.join(missing, ", ") <>
              ". A store must provide both writes and range reads; remote write alone is incomplete."
    end

    adapter
  end

  @doc """
  Records the organization's `samples`. A sample without a finite value or
  with an overlong series name is left out rather than failing the rest.
  """
  def write(%Scope{organization_id: organization_id}, samples) when is_list(samples) do
    case Enum.flat_map(samples, &normalize/1) do
      [] -> :ok
      samples -> adapter!().write(organization_id, samples)
    end
  end

  defp normalize(%{series: series, at: %DateTime{} = at, value: value})
       when is_binary(series) and byte_size(series) in 1..@series_max do
    case to_float(value) do
      nil -> []
      value -> [%{series: series, at: at, value: value}]
    end
  end

  defp normalize(_sample), do: []

  defp to_float(%Decimal{} = value) do
    if Decimal.inf?(value) or Decimal.nan?(value), do: nil, else: Decimal.to_float(value)
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value
  defp to_float(_value), do: nil

  @doc """
  Reads the organization's `series` between `from` and `to` in buckets
  `bucket_seconds` wide, which must be a multiple of the adapter's bucket.
  The range widens to whole buckets. Every series gets every bucket in the
  range, oldest first, with empty ones as gaps.

  Returns `{:error, :invalid_bucket}` for a bucket width the adapter cannot
  serve, `{:error, :too_many_buckets}` past #{@max_buckets} buckets, and
  `{:error, :too_many_points}` when the distinct series times the buckets
  pass #{@max_points}, before anything is read or allocated.
  """
  def range(%Scope{organization_id: organization_id}, series, from, to, bucket_seconds)
      when is_list(series) and is_integer(bucket_seconds) do
    adapter = adapter!()
    series = Enum.uniq(series)

    with :ok <- check_width(adapter, bucket_seconds),
         {from, to} = align(from, to, bucket_seconds),
         :ok <- check_count(from, to, bucket_seconds),
         :ok <- check_points(series, from, to, bucket_seconds),
         {:ok, found} <- read(adapter, organization_id, series, from, to, bucket_seconds) do
      starts = starts(from, to, bucket_seconds)
      {:ok, Map.new(series, &{&1, fill(starts, Map.get(found, &1, []))})}
    end
  end

  defp check_points(series, from, to, bucket_seconds) do
    if length(series) * div(DateTime.diff(to, from), bucket_seconds) <= @max_points,
      do: :ok,
      else: {:error, :too_many_points}
  end

  defp check_width(adapter, bucket_seconds) do
    native = adapter.bucket_seconds()

    if bucket_seconds > 0 and rem(bucket_seconds, native) == 0,
      do: :ok,
      else: {:error, :invalid_bucket}
  end

  defp check_count(from, to, bucket_seconds) do
    if div(DateTime.diff(to, from), bucket_seconds) <= @max_buckets,
      do: :ok,
      else: {:error, :too_many_buckets}
  end

  defp read(_adapter, _organization_id, [], _from, _to, _bucket_seconds), do: {:ok, %{}}

  defp read(adapter, organization_id, series, from, to, bucket_seconds),
    do: adapter.range(organization_id, series, from, to, bucket_seconds)

  @doc false
  def align(from, to, bucket_seconds) do
    from = floor_to(from, bucket_seconds)
    end_floor = floor_to(to, bucket_seconds)

    to =
      if DateTime.compare(end_floor, to) == :eq,
        do: end_floor,
        else: DateTime.add(end_floor, bucket_seconds, :second)

    if DateTime.compare(to, from) == :gt,
      do: {from, to},
      else: {from, DateTime.add(from, bucket_seconds, :second)}
  end

  @doc "`at` rounded down to a multiple of `bucket_seconds` since the epoch, in whole seconds."
  def floor_to(%DateTime{} = at, bucket_seconds) do
    seconds = DateTime.to_unix(at)
    DateTime.from_unix!(seconds - Integer.mod(seconds, bucket_seconds))
  end

  defp starts(from, to, bucket_seconds) do
    from
    |> Stream.iterate(&DateTime.add(&1, bucket_seconds, :second))
    |> Enum.take_while(&(DateTime.compare(&1, to) == :lt))
  end

  defp fill(starts, buckets) do
    found = Map.new(buckets, &{DateTime.to_unix(&1.start), &1})
    Enum.map(starts, &Map.get(found, DateTime.to_unix(&1), Bucket.gap(&1)))
  end

  @doc "How long the configured adapter keeps history."
  def retention, do: adapter!().retention()
end
