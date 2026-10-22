defmodule Renga.Telemetry.StoreTest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures
  import Renga.PowerReadingFixtures

  alias Renga.Accounts.Scope
  alias Renga.Telemetry
  alias Renga.Telemetry.Batch
  alias Renga.Telemetry.Store
  alias Renga.Telemetry.Store.Bucket

  setup do
    organization = organization_fixture()
    now = Renga.Time.utc_now_ms()
    # Two whole hours back, so every sample lands in a past bucket.
    hour = DateTime.add(Store.floor_to(now, 3_600), -7_200, :second)
    %{organization: organization, scope: %Scope{organization_id: organization.id}, hour: hour}
  end

  defp at(hour, seconds), do: DateTime.add(hour, seconds, :second)

  defp write!(scope, series, points) do
    :ok =
      Store.write(scope, for({at, value} <- points, do: %{series: series, at: at, value: value}))
  end

  test "five-minute buckets give average, minimum, maximum, last, and count, with gaps",
       %{scope: scope, hour: hour} do
    write!(scope, "power/feed/a/apparent_power", [
      {at(hour, 0), 100},
      {at(hour, 120), Decimal.new("130.5")},
      # Written out of order: the last value is the later sample's.
      {at(hour, 240), 120.0},
      {at(hour, 60), 90},
      {at(hour, 600), 200}
    ])

    # A later write into the same bucket merges with it.
    write!(scope, "power/feed/a/apparent_power", [{at(hour, 290), 80}])

    {:ok, %{"power/feed/a/apparent_power" => buckets}} =
      Store.range(scope, ["power/feed/a/apparent_power"], hour, at(hour, 900), 300)

    assert [first, gap, third] = buckets

    assert first == %Bucket{
             start: hour,
             count: 5,
             average: (100 + 130.5 + 120 + 90 + 80) / 5,
             minimum: 80.0,
             maximum: 130.5,
             last: 80.0
           }

    assert Bucket.gap?(gap) and gap.start == at(hour, 300)
    assert {gap.average, gap.minimum, gap.maximum, gap.last} == {nil, nil, nil, nil}
    assert %Bucket{count: 1, average: 200.0, last: 200.0} = third
  end

  test "wider buckets merge the five-minute ones", %{scope: scope, hour: hour} do
    write!(scope, "s", [{at(hour, 0), 10}, {at(hour, 1_000), 30}, {at(hour, 3_599), 20}])

    {:ok, %{"s" => [bucket]}} = Store.range(scope, ["s"], hour, at(hour, 3_600), 3_600)

    assert %Bucket{start: ^hour, count: 3, average: 20.0, minimum: 10.0, maximum: 30.0} = bucket
    assert bucket.last == 20.0
  end

  test "a range widens to whole buckets and fills unknown series with gaps",
       %{scope: scope, hour: hour} do
    write!(scope, "s", [{at(hour, 10), 1}])

    {:ok, result} = Store.range(scope, ["s", "never"], at(hour, 20), at(hour, 301), 300)

    assert [%Bucket{start: ^hour, count: 1}, %Bucket{count: 0}] = result["s"]
    assert Enum.map(result["never"], & &1.count) == [0, 0]
  end

  test "reads are scoped to the organization", %{scope: scope, hour: hour} do
    other = %Scope{organization_id: organization_fixture().id}
    write!(other, "s", [{at(hour, 0), 1}])

    {:ok, %{"s" => [bucket]}} = Store.range(scope, ["s"], hour, at(hour, 300), 300)
    assert Bucket.gap?(bucket)
  end

  test "retention is enforced on write, read, and prune", %{scope: scope, organization: org} do
    now = Renga.Time.utc_now_ms()
    old = DateTime.add(now, -31 * 86_400, :second)

    write!(scope, "s", [{old, 1}, {DateTime.add(now, 3_600, :second), 2}])
    assert Repo.aggregate("telemetry_buckets", :count) == 0

    # A bucket left past retention is neither read nor kept.
    Repo.query!(
      """
      INSERT INTO telemetry_buckets VALUES ($1, 's', $2, 1, 1, 1, 1, 1, $2)
      """,
      [Ecto.UUID.dump!(org.id), DateTime.to_naive(Store.floor_to(old, 300))]
    )

    {:ok, %{"s" => buckets}} =
      Store.range(scope, ["s"], Store.floor_to(old, 300), DateTime.add(old, 300, :second), 300)

    assert Enum.all?(buckets, &Bucket.gap?/1)
    assert Store.retention() == {:enforced, 30 * 86_400}
    assert %{history: 1} = Telemetry.prune(now)
    assert Repo.aggregate("telemetry_buckets", :count) == 0
  end

  test "values that are not finite numbers are left out", %{scope: scope, hour: hour} do
    :ok =
      Store.write(scope, [
        %{series: "s", at: at(hour, 0), value: nil},
        %{series: "s", at: at(hour, 0), value: Decimal.new("NaN")},
        %{series: String.duplicate("x", 256), at: at(hour, 0), value: 1},
        %{series: "s", at: at(hour, 0), value: 4}
      ])

    {:ok, %{"s" => [bucket]}} = Store.range(scope, ["s"], hour, at(hour, 300), 300)
    assert bucket.count == 1 and bucket.average == 4.0
  end

  test "rejects bucket widths the adapter cannot serve, and overlong ranges",
       %{scope: scope, hour: hour} do
    assert Store.range(scope, ["s"], hour, at(hour, 600), 60) == {:error, :invalid_bucket}

    assert Store.range(scope, ["s"], at(hour, -30 * 86_400), hour, 300) ==
             {:error, :too_many_buckets}
  end

  defmodule RemoteWriteOnly do
    def write(_organization_id, _samples), do: :ok
    def bucket_seconds, do: 60
    def retention, do: {:managed, "Kept by the backend."}
  end

  test "a store without range reads is refused" do
    assert_raise ArgumentError, ~r/does not implement range\/5.*remote write alone/, fn ->
      Store.validate!(RemoteWriteOnly)
    end

    assert Store.validate!(Renga.Telemetry.Store.Postgres) == Renga.Telemetry.Store.Postgres
  end

  test "replay IDs are kept for a week", %{organization: organization} do
    source = power_stream_fixture(organization)
    now = Renga.Time.utc_now_ms()

    for {replay_id, days} <- [{"old", 8}, {"recent", 6}] do
      Repo.insert!(%Batch{
        organization_id: organization.id,
        source_id: source.id,
        replay_id: replay_id,
        version: 1,
        payload_digest: "digest",
        sample_count: 1,
        received_at: DateTime.add(now, -days * 86_400, :second)
      })
    end

    assert %{batches: 1} = Telemetry.prune(now)
    assert [%Batch{replay_id: "recent"}] = Repo.all(Batch)
  end
end
