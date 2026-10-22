defmodule Renga.Power.MeasuredTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures
  import Renga.PowerReadingFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.Measured
  alias Renga.Power.Readings

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
    stream = power_stream_fixture(organization)
    %{scope: scope, panel: panel, stream: stream, organization: organization}
  end

  # 230 V × 16 A at 80%: 2,944 VA usable, 12.8 A.
  defp feed!(scope, panel, attrs \\ %{}) do
    {:ok, feed} =
      Power.create_feed(
        scope,
        panel.id,
        Map.merge(
          %{
            name: "A#{System.unique_integer([:positive])}",
            supply: "ac",
            phase: "single",
            voltage: "230",
            amperage: "16"
          },
          attrs
        )
      )

    feed
  end

  # A PDU with an inlet and `count` outlets, plugged into `feed` and
  # polled as `target`.
  defp pdu!(context, feed, count \\ 2) do
    %{scope: scope, stream: stream} = context

    outlets =
      for number <- 1..count//1,
          do: %{kind: "power_outlet", name: "#{number}", attributes: %{"inlet" => "Inlet"}}

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-#{System.unique_integer([:positive])}", [
        %{kind: "power_port", name: "Inlet"} | outlets
      ])

    %{ports: [inlet]} = Power.list_device_endpoints(scope, pdu.id)
    {:ok, _} = Cables.connect(scope, %{power_port_id: inlet.id, power_feed_id: feed.id})
    target_resource_fixture(stream, "10.0.0.5", pdu)
    pdu
  end

  defp measured!(scope, feed), do: Map.fetch!(Measured.for_feeds(scope, [feed]), feed.id)

  defp inlet!(stream, quantity, value, attrs) do
    reading_fixture(
      stream,
      [target: "10.0.0.5", boundary: "feed", quantity: quantity, value: value] ++ attrs
    )
  end

  defp outlet!(stream, name, value, attrs \\ []) do
    reading_fixture(
      stream,
      [
        target: "10.0.0.5",
        sensor: "outlet/#{name}",
        boundary: "outlet",
        quantity: "apparent_power",
        component: {"power_outlet", name},
        value: value
      ] ++ attrs
    )
  end

  test "a feed with no cable or no readings has unknown measured load", context do
    %{scope: scope, panel: panel} = context
    feed = feed!(scope, panel)
    assert %Measured{status: :unknown, load: nil, gaps: [:no_cable]} = measured!(scope, feed)

    pdu!(context, feed)
    measured = measured!(scope, feed)
    assert {measured.status, measured.load, measured.headroom} == {:unknown, nil, nil}
    assert :no_readings in measured.gaps
  end

  test "a complete inlet meter measures the feed", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed)
    inlet!(stream, "apparent_power", 1200, coverage: "complete")

    measured = measured!(scope, feed)
    assert {measured.status, measured.basis, measured.gaps} == {:ok, :aggregate, []}
    assert Decimal.eq?(measured.load, 1200)
    assert Decimal.eq?(measured.headroom, "1744.0")
    assert Measured.percent(measured) == 41
    assert measured.as_of
  end

  test "an aggregate is never added to its constituents", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed)
    inlet!(stream, "apparent_power", 1000, coverage: "complete")
    outlet!(stream, "1", 600)
    outlet!(stream, "2", 500)

    measured = measured!(scope, feed)
    assert measured.basis == :aggregate
    assert Decimal.eq?(measured.load, 1000)
    assert length(measured.readings) == 1
  end

  test "an inlet meter that does not cover everything is not used", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed)
    inlet!(stream, "apparent_power", 1000, coverage: "partial")

    measured = measured!(scope, feed)
    assert {measured.status, measured.load} == {:unknown, nil}
    assert :partial_coverage in measured.gaps

    # Every outlet measured: their sum is the load.
    outlet!(stream, "1", 600)
    outlet!(stream, "2", 500)
    measured = measured!(scope, feed)
    assert {measured.status, measured.basis} == {:ok, :outlets}
    assert Decimal.eq?(measured.load, 1100)
  end

  test "an outlet without a reading leaves the sum a lower bound", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed, 3)
    outlet!(stream, "1", 600)
    outlet!(stream, "2", 500)

    measured = measured!(scope, feed)
    assert {measured.status, measured.load, measured.headroom} == {:unknown, nil, nil}
    assert Decimal.eq?(measured.known, 1100)
    assert {:outlets_unmeasured, 1} in measured.gaps

    # What is known already proves the feed over its limit.
    outlet!(stream, "2", 2500)
    assert %Measured{status: :over, load: nil} = measured!(scope, feed)
  end

  test "stale, failed, and invalid readings never count", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed)

    stale = DateTime.add(Renga.Time.utc_now_ms(), -600, :second)
    inlet!(stream, "apparent_power", 1200, coverage: "complete", event_at: stale)

    measured = measured!(scope, feed)
    assert {measured.status, measured.load} == {:unknown, nil}
    assert :ineligible in measured.gaps

    outlet!(stream, "1", 600)
    outlet!(stream, "2", nil, status: "failed")
    measured = measured!(scope, feed)
    assert {measured.status, measured.load} == {:unknown, nil}
    assert Decimal.eq?(measured.known, 600)
  end

  test "real power on an AC feed needs a measured power factor", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed)
    inlet!(stream, "real_power", 900, coverage: "complete", sensor: "inlet")

    measured = measured!(scope, feed)
    assert {measured.status, measured.load} == {:unknown, nil}
    assert :unconverted in measured.gaps

    inlet!(stream, "power_factor", 0.9, coverage: "complete", sensor: "inlet")
    measured = measured!(scope, feed)
    assert measured.status == :ok
    assert Decimal.eq?(measured.load, 1000)
  end

  test "a DC feed compares measured watts", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel, %{supply: "dc", voltage: "48", amperage: "50"})
    pdu!(context, feed)
    inlet!(stream, "real_power", 1500, coverage: "complete")

    measured = measured!(scope, feed)
    assert measured.status == :ok
    assert measured.capacity.unit == :w
    assert Decimal.eq?(measured.headroom, "420")
  end

  test "measured current over the circuit's limit is an overload", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)
    pdu!(context, feed)
    inlet!(stream, "current", 13.5, coverage: "complete")

    measured = measured!(scope, feed)
    assert measured.status == :over
    assert Decimal.eq?(measured.current_limit, "12.8")
  end

  test "a three-phase feed needs every leg measured, and one leg can be over", context do
    %{scope: scope, panel: panel, stream: stream} = context
    # √3 × 400 V × 32 A × 80%: about 17,734 VA usable, 25.6 A per leg.
    feed = feed!(scope, panel, %{phase: "three", voltage: "400", amperage: "32"})
    pdu!(context, feed)
    inlet!(stream, "apparent_power", 9000, coverage: "complete")

    measured = measured!(scope, feed)
    assert {measured.status, measured.headroom} == {:unknown, nil}
    assert :legs_unmeasured in measured.gaps

    for {leg, amps} <- [{"a", 10}, {"b", 11}] do
      reading_fixture(stream,
        target: "10.0.0.5",
        sensor: "leg/#{leg}",
        boundary: "leg",
        leg: leg,
        quantity: "current",
        value: amps
      )
    end

    assert %Measured{status: :unknown} = measured!(scope, feed)

    reading_fixture(stream,
      target: "10.0.0.5",
      sensor: "leg/c",
      boundary: "leg",
      leg: "c",
      quantity: "current",
      value: 27
    )

    measured = measured!(scope, feed)
    assert measured.status == :over
    assert Enum.map(measured.legs, &Decimal.to_integer(&1.current)) == [10, 11, 27]
  end

  test "a device's own supply on a feed is measured at the supply's input", context do
    %{scope: scope, panel: panel, stream: stream} = context
    feed = feed!(scope, panel)

    {server, _expected} =
      assigned_server_fixture(scope, "db-1", [
        %{kind: "power_port", name: "PSU1"},
        %{kind: "power_port", name: "PSU2"}
      ])

    %{ports: [psu1, _psu2]} = Power.list_device_endpoints(scope, server.id)
    {:ok, _} = Cables.connect(scope, %{power_port_id: psu1.id, power_feed_id: feed.id})
    target_resource_fixture(stream, "bmc-db-1", server)

    reading_fixture(stream,
      target: "bmc-db-1",
      boundary: "supply_input",
      quantity: "apparent_power",
      component: {"power_port", "PSU2"},
      value: 400
    )

    assert %Measured{status: :unknown, load: nil} = measured!(scope, feed)

    reading_fixture(stream,
      target: "bmc-db-1",
      boundary: "supply_input",
      quantity: "apparent_power",
      component: {"power_port", "PSU1"},
      value: 350
    )

    measured = measured!(scope, feed)
    assert {measured.status, measured.basis} == {:ok, :supply}
    assert Decimal.eq?(measured.load, 350)
  end

  describe "source precedence" do
    test "a native reading wins over an exporter's only while it is eligible", context do
      %{scope: scope, organization: organization, stream: stream} = context

      {pdu, _expected} =
        assigned_server_fixture(scope, "pdu-x", [%{kind: "power_port", name: "Inlet"}])

      target_resource_fixture(stream, "10.0.0.9", pdu)
      exporter_stream = power_stream_fixture(organization, "bmc_power")
      target_resource_fixture(exporter_stream, "127.0.0.1:9290", pdu)

      reading = fn source, target, value, attrs ->
        reading_fixture(
          source,
          [target: target, boundary: "feed", quantity: "real_power", value: value] ++ attrs
        )
      end

      reading.(stream, "10.0.0.9", 500, sensor: "inlet")
      reading.(exporter_stream, "127.0.0.1:9290", 520, origin: "exporter")

      pdu_id = pdu.id

      assert %{^pdu_id => [entry]} =
               Readings.for_resources(scope, [pdu.id], Renga.Time.utc_now_ms())

      assert {entry.eligible?, entry.reading.origin} == {true, "native"}
      assert Decimal.eq?(entry.reading.value, 500)

      # A failed native read hands over to the exporter's fresh value.
      reading.(stream, "10.0.0.9", nil,
        sensor: "inlet",
        status: "failed",
        event_at: DateTime.add(Renga.Time.utc_now_ms(), 1, :second)
      )

      assert %{^pdu_id => [entry]} =
               Readings.for_resources(scope, [pdu.id], Renga.Time.utc_now_ms())

      assert {entry.eligible?, entry.reading.origin} == {true, "exporter"}
    end

    test "different boundaries and windows are never equivalent", context do
      %{scope: scope, stream: stream} = context

      {pdu, _expected} =
        assigned_server_fixture(scope, "pdu-y", [%{kind: "power_port", name: "Inlet"}])

      target_resource_fixture(stream, "10.0.0.9", pdu)

      for {boundary, window} <- [{"feed", 0}, {"feed", 60}, {"supply_output", 0}] do
        reading_fixture(stream,
          target: "10.0.0.9",
          sensor: "#{boundary}-#{window}",
          boundary: boundary,
          window_seconds: window,
          value: 100
        )
      end

      assert %{} = readings = Readings.for_resources(scope, [pdu.id], Renga.Time.utc_now_ms())
      assert length(readings[pdu.id]) == 3
    end

    test "a target that reports several resources names none of them", context do
      %{scope: scope, stream: stream} = context
      {first, _} = assigned_server_fixture(scope, "chassis-1", [])
      {second, _} = assigned_server_fixture(scope, "chassis-2", [])
      target_resource_fixture(stream, "10.0.0.7", first)
      target_resource_fixture(stream, "10.0.0.7", second)
      reading_fixture(stream, target: "10.0.0.7", boundary: "feed", value: 100)

      assert Readings.for_resources(scope, [first.id, second.id], Renga.Time.utc_now_ms()) ==
               %{}
    end
  end
end
