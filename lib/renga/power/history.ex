defmodule Renga.Power.History do
  @moduledoc """
  Measured-load history for charts (RFD 10, "Measured history").

  Once a minute, `record/2` writes each feed's measured load and each
  device's measured input power to the telemetry store
  (`Renga.Telemetry.Store`), as the current-reading rules compute them at
  that moment. A load that is unknown then is not written, so it shows as a
  gap. Findings and capacity read current readings, never these series, so
  the store failing or being swapped changes neither.

  A device's input power is its host input meter when that is current, and
  otherwise the sum of its supplies' inputs when every current power port
  has one. A partial sum would understate the load, so it is a gap too.

  Every node's sweeper may call `record/2`; the minute is claimed per
  organization first, so each minute is written once.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Power.Capacity
  alias Renga.Power.Feed
  alias Renga.Power.Measured
  alias Renga.Power.Port
  alias Renga.Power.Readings
  alias Renga.Repo
  alias Renga.Telemetry.Store

  @doc "The series of a feed's measured load, in its capacity unit."
  def feed_series(%Feed{} = feed),
    do: "power/feed/#{feed.id}/load_#{Capacity.unit(feed)}"

  @doc "The series of a device's measured input power, in W."
  def device_series(resource_id), do: "power/device/#{resource_id}/input_w"

  @doc """
  Writes the organization's measured loads for the minute of `now`, unless
  that minute is already written. Returns the number of samples written, or
  `:recorded` when another sweep wrote this minute.
  """
  def record(%Scope{organization_id: organization_id} = scope, now \\ Renga.Time.utc_now_ms()) do
    minute = Store.floor_to(now, 60)

    if claim(organization_id, minute) do
      samples = feed_samples(scope, now, minute) ++ device_samples(scope, now, minute)
      :ok = Store.write(scope, samples)
      length(samples)
    else
      :recorded
    end
  end

  defp claim(organization_id, minute) do
    %{num_rows: claimed} =
      Repo.query!(
        """
        INSERT INTO telemetry_marks AS mark (organization_id, name, recorded_at)
        VALUES ($1, 'power_history', $2)
        ON CONFLICT (organization_id, name) DO UPDATE SET recorded_at = EXCLUDED.recorded_at
        WHERE mark.recorded_at < EXCLUDED.recorded_at
        """,
        [Ecto.UUID.dump!(organization_id), DateTime.to_naive(minute)]
      )

    claimed == 1
  end

  defp feed_samples(%Scope{organization_id: organization_id} = scope, now, minute) do
    feeds =
      Feed
      |> where([feed], feed.organization_id == ^organization_id)
      |> Repo.all()

    for {_id, %Measured{load: %Decimal{} = load, feed: feed}} <-
          Measured.for_feeds(scope, feeds, now),
        do: %{series: feed_series(feed), at: minute, value: load}
  end

  defp device_samples(%Scope{organization_id: organization_id} = scope, now, minute) do
    ports =
      Port
      |> where([port], port.organization_id == ^organization_id and is_nil(port.retired_at))
      |> Repo.all()
      |> Enum.group_by(& &1.resource_id)

    readings = Readings.for_resources(scope, Map.keys(ports), now)

    for {resource_id, ports} <- ports,
        %Decimal{} = input <- [input(Map.get(readings, resource_id, []), ports)],
        do: %{series: device_series(resource_id), at: minute, value: input}
  end

  @doc false
  def input(entries, ports) do
    power =
      entries
      |> Enum.filter(&(&1.eligible? and &1.reading.quantity == "real_power"))
      |> Enum.map(& &1.reading)

    case shortest(Enum.filter(power, &(&1.boundary == "host_input"))) do
      nil -> supplies_sum(power, ports)
      host -> host.value
    end
  end

  defp supplies_sum(power, ports) do
    by_supply =
      power
      |> Enum.filter(&(&1.boundary == "supply_input" and &1.component_kind == "power_port"))
      |> Enum.group_by(& &1.component_name)

    values = Enum.map(ports, &(by_supply |> Map.get(&1.name, []) |> shortest()))

    if Enum.all?(values), do: values |> Enum.map(& &1.value) |> Enum.reduce(&Decimal.add/2)
  end

  # Of equivalent readings over different windows, the most recent picture.
  defp shortest([]), do: nil
  defp shortest(readings), do: Enum.min_by(readings, & &1.window_ms)
end
