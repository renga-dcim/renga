defmodule Renga.Power.HistoryTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures
  import Renga.PowerReadingFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Power
  alias Renga.Power.Cables
  alias Renga.Power.History
  alias Renga.Telemetry.Store
  alias Renga.Telemetry.Store.Bucket

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})

    {:ok, feed} =
      Power.create_feed(scope, panel.id, %{
        name: "A1",
        supply: "ac",
        phase: "single",
        voltage: "230",
        amperage: "16"
      })

    {pdu, _expected} =
      assigned_server_fixture(scope, "pdu-a1", [
        %{kind: "power_port", name: "Inlet"},
        %{kind: "power_outlet", name: "1", attributes: %{"inlet" => "Inlet"}}
      ])

    %{ports: [inlet]} = Power.list_device_endpoints(scope, pdu.id)
    {:ok, _} = Cables.connect(scope, %{power_port_id: inlet.id, power_feed_id: feed.id})
    pdus = power_stream_fixture(organization)
    target_resource_fixture(pdus, "10.0.0.5", pdu)

    {server, _expected} =
      assigned_server_fixture(scope, "db-1", [
        %{kind: "power_port", name: "PSU1"},
        %{kind: "power_port", name: "PSU2"}
      ])

    bmcs = power_stream_fixture(organization, "bmc_power")
    target_resource_fixture(bmcs, "bmc-db-1", server)

    %{scope: scope, feed: feed, pdus: pdus, server: server, bmcs: bmcs}
  end

  defp supply!(bmcs, name, value) do
    reading_fixture(bmcs,
      target: "bmc-db-1",
      sensor: "#{name}/input",
      boundary: "supply_input",
      component: {"power_port", name},
      value: value
    )
  end

  defp buckets(scope, series, now) do
    from = Store.floor_to(now, 300)
    {:ok, %{^series => buckets}} = Store.range(scope, [series], from, now, 300)
    buckets
  end

  test "records each feed's measured load and each device's input once a minute", context do
    %{scope: scope, feed: feed, pdus: pdus, server: server, bmcs: bmcs} = context

    reading_fixture(pdus,
      target: "10.0.0.5",
      boundary: "feed",
      quantity: "apparent_power",
      coverage: "complete",
      value: 1200
    )

    supply!(bmcs, "PSU1", 180)
    supply!(bmcs, "PSU2", 170)
    now = Renga.Time.utc_now_ms()

    assert History.record(scope, now) == 2
    # Another node's sweep in the same minute writes nothing.
    assert History.record(scope, now) == :recorded

    assert History.feed_series(feed) == "power/feed/#{feed.id}/load_va"
    assert [%Bucket{count: 1, average: 1200.0}] = buckets(scope, History.feed_series(feed), now)

    assert [%Bucket{count: 1, average: 350.0}] =
             buckets(scope, History.device_series(server.id), now)

    # The next minute is written again.
    assert History.record(scope, DateTime.add(now, 60, :second)) == 2
  end

  test "a device missing one supply's input, or a stale meter, is a gap", context do
    %{scope: scope, feed: feed, pdus: pdus, server: server, bmcs: bmcs} = context

    reading_fixture(pdus,
      target: "10.0.0.5",
      boundary: "feed",
      quantity: "apparent_power",
      coverage: "complete",
      value: 1200,
      event_at: DateTime.add(Renga.Time.utc_now_ms(), -600, :second)
    )

    supply!(bmcs, "PSU1", 180)
    now = Renga.Time.utc_now_ms()

    assert History.record(scope, now) == 0
    assert [%Bucket{count: 0}] = buckets(scope, History.feed_series(feed), now)
    assert [%Bucket{count: 0}] = buckets(scope, History.device_series(server.id), now)
  end

  test "a host input meter is the device's input over its supplies", context do
    %{scope: scope, server: server, bmcs: bmcs} = context
    supply!(bmcs, "PSU1", 180)
    reading_fixture(bmcs, target: "bmc-db-1", sensor: "host", boundary: "host_input", value: 330)
    now = Renga.Time.utc_now_ms()

    assert History.record(scope, now) == 1

    assert [%Bucket{average: 330.0}] = buckets(scope, History.device_series(server.id), now)
  end

  test "readings that cover only part of a device are not its input", context do
    %{scope: scope, server: server, bmcs: bmcs} = context

    reading_fixture(bmcs,
      target: "bmc-db-1",
      sensor: "host",
      boundary: "host_input",
      coverage: "partial",
      value: 90
    )

    supply!(bmcs, "PSU1", 180)
    supply!(bmcs, "PSU2", 170)
    now = Renga.Time.utc_now_ms()

    # A partial host meter gives way to the complete supplies.
    assert History.record(scope, now) == 1
    assert [%Bucket{average: 350.0}] = buckets(scope, History.device_series(server.id), now)
  end

  test "a partial supply input leaves a gap, and a real zero is kept", context do
    %{scope: scope, server: server, bmcs: bmcs} = context

    reading_fixture(bmcs,
      target: "bmc-db-1",
      sensor: "PSU1/input",
      boundary: "supply_input",
      component: {"power_port", "PSU1"},
      coverage: "partial",
      value: 180,
      event_at: DateTime.add(Renga.Time.utc_now_ms(), -10, :second)
    )

    supply!(bmcs, "PSU2", 170)
    now = Renga.Time.utc_now_ms()
    assert History.record(scope, now) == 0

    supply!(bmcs, "PSU1", 0)
    supply!(bmcs, "PSU2", 0)
    later = DateTime.add(now, 60, :second)
    assert History.record(scope, later) == 1
    assert [%Bucket{average: +0.0}] = buckets(scope, History.device_series(server.id), later)
  end

  test "a device with a host meter but no modeled ports is recorded", context do
    %{scope: scope, bmcs: bmcs} = context

    {:ok, portless} =
      Renga.Inventory.create_resource(scope, %{
        kind: "server",
        name: "bare-1",
        lifecycle_state: "active"
      })

    target_resource_fixture(bmcs, "bmc-bare-1", portless)

    reading_fixture(bmcs,
      target: "bmc-bare-1",
      sensor: "host",
      boundary: "host_input",
      value: 410
    )

    reading_fixture(bmcs,
      target: "bmc-bare-1",
      sensor: "PSU1/input",
      boundary: "supply_input",
      component: {"power_port", "PSU1"},
      value: 200
    )

    now = Renga.Time.utc_now_ms()
    assert History.record(scope, now) == 1
    assert [%Bucket{average: 410.0}] = buckets(scope, History.device_series(portless.id), now)
  end
end
