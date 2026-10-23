defmodule RengaWeb.TrendComponents do
  @moduledoc """
  Measured trends from the telemetry store (`Renga.Telemetry.Store`), drawn
  as a line of bucket averages over a band from each bucket's minimum to its
  maximum (RFD 10, "Measured history").

  A bucket without samples is a gap: the line breaks there and is never
  drawn through zero. Charts only show history; nothing that decides a
  finding or capacity reads them.
  """

  use RengaWeb, :html

  alias Renga.Telemetry.Store
  alias Renga.Telemetry.Store.Bucket

  @ranges [
    {"24h", "24 hours", 86_400, 300},
    {"7d", "7 days", 7 * 86_400, 1_800},
    {"30d", "30 days", 30 * 86_400, 3_600}
  ]

  @width 1_000
  @height 100

  @doc "The trend periods, as URL values."
  def ranges, do: Enum.map(@ranges, &elem(&1, 0))

  @doc "A period from a URL value, defaulting to 24 hours."
  def range(value) when value in ["24h", "7d", "30d"], do: value
  def range(_value), do: "24h"

  @doc """
  The buckets of `series` over the period ending at `now`. A store that
  fails to answer gives no trend rather than failing the page.
  """
  def load(scope, series, range, now \\ Renga.Time.utc_now_ms()) do
    {_value, _label, seconds, bucket_seconds} = List.keyfind(@ranges, range, 0)
    to = Store.floor_to(now, bucket_seconds) |> DateTime.add(bucket_seconds, :second)
    from = DateTime.add(to, -seconds, :second)

    case Store.range(scope, [series], from, to, bucket_seconds) do
      {:ok, %{^series => buckets}} -> buckets
      {:error, _reason} -> nil
    end
  rescue
    _error -> nil
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :buckets, :list, default: nil, doc: "nil when the store could not be read"
  attr :unit, :string, required: true
  attr :limit, :any, default: nil, doc: "a level to mark, such as usable capacity"
  attr :limit_label, :string, default: nil
  attr :range, :string, required: true
  attr :patch, :any, required: true, doc: "a function from a period to its patch path"

  def trend_chart(assigns) do
    buckets = assigns.buckets || []
    values = for %Bucket{maximum: maximum} <- buckets, maximum, do: maximum
    limit = assigns.limit && to_float(assigns.limit)
    scale = scale(Enum.max([limit || 0.0 | values], fn -> 0.0 end))

    assigns =
      assign(assigns,
        scale: scale,
        lines: lines(buckets, scale),
        bands: bands(buckets, scale),
        limit_y: limit && y(limit, scale),
        summary: summary(assigns.buckets, assigns),
        first: List.first(buckets),
        label: range_label(assigns.range),
        width: @width,
        height: @height
      )

    ~H"""
    <figure id={@id} class="space-y-2">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <figcaption class="text-sm font-semibold">{@title}</figcaption>
        <.segmented id={"#{@id}-range"} label="Period">
          <:option
            :for={range <- ranges()}
            id={"#{@id}-range-#{range}"}
            patch={@patch.(range)}
            active={range == @range}
          >
            {range}
          </:option>
        </.segmented>
      </div>

      <div class="flex gap-2">
        <div
          class="flex w-12 shrink-0 flex-col justify-between text-right font-mono text-[11px] tabular-nums text-fg-muted"
          aria-hidden="true"
        >
          <span>{format(@scale)}</span>
          <span>0</span>
        </div>
        <svg
          id={"#{@id}-plot"}
          viewBox={"0 0 #{@width} #{@height}"}
          preserveAspectRatio="none"
          role="img"
          aria-label={@summary}
          class="h-32 min-w-0 flex-1 rounded-sm border border-line bg-sunken"
        >
          <path :for={band <- @bands} d={band} class="fill-accent/15" />
          <line
            :if={@limit_y}
            id={"#{@id}-limit"}
            x1="0"
            x2={@width}
            y1={@limit_y}
            y2={@limit_y}
            class="stroke-crit"
            stroke-width="1"
            stroke-dasharray="6 4"
            vector-effect="non-scaling-stroke"
          />
          <path
            :for={line <- @lines}
            d={line}
            class="fill-none stroke-accent"
            stroke-width="1.5"
            stroke-linejoin="round"
            vector-effect="non-scaling-stroke"
          />
        </svg>
      </div>

      <div class="flex justify-between pl-14 text-[11px] text-fg-muted">
        <time :if={@first} datetime={DateTime.to_iso8601(@first.start)}>
          {RengaWeb.Format.datetime(@first.start)}
        </time>
        <span>Now</span>
      </div>

      <p id={"#{@id}-summary"} class="text-xs text-fg-muted">
        {@summary}<span :if={@limit_label}> The dashed line is {@limit_label}.</span>
      </p>
    </figure>
    """
  end

  defp summary(nil = _buckets, _assigns), do: "Measured history is unavailable right now."

  defp summary(buckets, assigns) do
    measured = Enum.reject(buckets, &Bucket.gap?/1)
    label = range_label(assigns.range)

    case measured do
      [] ->
        "No measurements in the last #{label}."

      measured ->
        peak = measured |> Enum.map(& &1.maximum) |> Enum.max()
        count = measured |> Enum.map(& &1.count) |> Enum.sum()
        average = Enum.sum(Enum.map(measured, &(&1.average * &1.count))) / count
        gaps = length(buckets) - length(measured)

        "Over the last #{label}: average #{format(average)} #{assigns.unit}, " <>
          "peak #{format(peak)} #{assigns.unit}." <>
          if(gaps > 0, do: " Gaps are periods without a current reading.", else: "")
    end
  end

  defp range_label(range), do: @ranges |> List.keyfind(range, 0) |> elem(1)

  # Runs of measured buckets: the line breaks at every gap.
  defp runs(buckets) do
    buckets
    |> Enum.with_index()
    |> Enum.chunk_by(fn {bucket, _index} -> Bucket.gap?(bucket) end)
    |> Enum.reject(fn [{bucket, _index} | _rest] -> Bucket.gap?(bucket) end)
    |> Enum.map(&{&1, length(buckets)})
  end

  defp lines(buckets, scale) do
    for {run, count} <- runs(buckets) do
      run
      |> points(count, scale, & &1.average)
      |> path()
    end
  end

  defp bands(buckets, scale) do
    for {run, count} <- runs(buckets) do
      upper = points(run, count, scale, & &1.maximum)
      lower = run |> points(count, scale, & &1.minimum) |> Enum.reverse()
      path(upper ++ lower) <> " Z"
    end
  end

  # A lone bucket spans its own width, so it still shows as a short line.
  defp points([{bucket, index}], count, scale, value) do
    step = @width / count
    y = y(value.(bucket), scale)
    [{index * step, y}, {(index + 1) * step, y}]
  end

  defp points(run, count, scale, value) do
    step = @width / count
    for {bucket, index} <- run, do: {(index + 0.5) * step, y(value.(bucket), scale)}
  end

  defp path([{x, y} | rest]) do
    Enum.reduce(rest, "M#{round1(x)} #{round1(y)}", fn {x, y}, path ->
      path <> " L#{round1(x)} #{round1(y)}"
    end)
  end

  defp y(value, scale), do: @height - value / scale * @height

  defp round1(number), do: Float.round(number * 1.0, 1)

  # A round top for the axis, at least the largest value.
  defp scale(maximum) when maximum <= 0, do: 1.0

  defp scale(maximum) do
    magnitude = :math.pow(10, Float.floor(:math.log10(maximum)))

    step =
      Enum.find([1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10], fn step -> step * magnitude >= maximum end)

    step * magnitude * 1.0
  end

  defp format(value) when value >= 100 do
    value
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format(value), do: value |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_number(value), do: value * 1.0
end
