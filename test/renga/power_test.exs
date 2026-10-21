defmodule Renga.PowerTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Power
  alias Renga.Power.Capacity
  alias Renga.Power.Feed

  setup do
    organization = organization_fixture()
    scope = scope_with_role(organization, "admin")
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})
    %{organization: organization, scope: scope, site: site}
  end

  defp scope_with_role(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  defp panel!(scope, site, name \\ "PDP-1") do
    {:ok, panel} = Power.create_panel(scope, %{site_id: site.id, name: name})
    panel
  end

  defp feed_attrs(attrs) do
    Map.merge(%{name: "A1", supply: "ac", phase: "single", voltage: "230", amperage: "16"}, attrs)
  end

  describe "capacity" do
    test "single-phase AC is volts times amps in VA" do
      capacity =
        Capacity.of(%Feed{
          supply: "ac",
          phase: "single",
          voltage: d("230"),
          amperage: d("16"),
          max_utilization: 80
        })

      assert capacity.unit == :va
      assert Decimal.equal?(capacity.rated, d("3680"))
      assert Decimal.equal?(capacity.usable, d("2944"))
      assert Capacity.format(capacity.usable, capacity.unit) == "2,944 VA"
    end

    test "three-phase AC uses the line-to-line voltage times root three" do
      capacity =
        Capacity.of(%Feed{
          supply: "ac",
          phase: "three",
          voltage: d("400"),
          amperage: d("32"),
          max_utilization: 80
        })

      assert capacity.unit == :va
      # √3 × 400 × 32 = 22,170.25…; usable at 80% = 17,736.2…
      assert Capacity.format(capacity.rated, :va) == "22,170 VA"
      assert Capacity.format(capacity.usable, :va) == "17,736 VA"
    end

    test "DC is volts times amps in W" do
      capacity =
        Capacity.of(%Feed{
          supply: "dc",
          phase: nil,
          voltage: d("48"),
          amperage: d("100"),
          max_utilization: 100
        })

      assert capacity.unit == :w
      assert Decimal.equal?(capacity.usable, d("4800"))
      assert Capacity.format(capacity.usable, :w) == "4,800 W"
    end

    test "totals keep VA and W apart" do
      feeds = [
        %Feed{
          supply: "ac",
          phase: "single",
          voltage: d("230"),
          amperage: d("16"),
          max_utilization: 100
        },
        %Feed{
          supply: "ac",
          phase: "single",
          voltage: d("230"),
          amperage: d("10"),
          max_utilization: 100
        },
        %Feed{supply: "dc", phase: nil, voltage: d("48"), amperage: d("50"), max_utilization: 50}
      ]

      totals = Power.capacity_totals(feeds)
      assert Decimal.equal?(totals.va, d("5980"))
      assert Decimal.equal?(totals.w, d("1200"))
      assert Power.capacity_totals([]) == %{}
    end
  end

  describe "panels and feeds" do
    test "a panel and its feeds get resource envelopes", %{scope: scope, site: site} do
      panel = panel!(scope, site)
      assert panel.resource.kind == "power_panel"
      assert panel.resource.display_name == "PDP-1"

      {:ok, feed} = Power.create_feed(scope, panel.id, feed_attrs(%{side: "a"}))
      assert feed.resource.kind == "power_feed"
      assert feed.resource.display_name == "PDP-1 / A1"
      assert feed.site_id == site.id

      assert [%{feeds: [%{id: feed_id}]}] = Power.list_panels(scope, site.id)
      assert feed_id == feed.id
    end

    test "renaming a panel relabels its feeds", %{scope: scope, site: site} do
      panel = panel!(scope, site)
      {:ok, feed} = Power.create_feed(scope, panel.id, feed_attrs(%{}))

      {:ok, _panel} = Power.update_panel(scope, panel, %{name: "PDP-2"})

      assert Inventory.get_resource!(scope, feed.resource_id).display_name == "PDP-2 / A1"
    end

    test "long names keep feed envelope labels within the resource limit", %{
      scope: scope,
      site: site
    } do
      panel = panel!(scope, site, String.duplicate("P", 255))
      {:ok, feed} = Power.create_feed(scope, panel.id, feed_attrs(%{name: "A1"}))

      created_label = Inventory.get_resource!(scope, feed.resource_id).display_name
      assert String.length(created_label) == 255
      assert String.ends_with?(created_label, " / A1")

      {:ok, feed} = Power.update_feed(scope, feed, %{name: String.duplicate("F", 255)})
      renamed_feed_label = Inventory.get_resource!(scope, feed.resource_id).display_name
      assert String.length(renamed_feed_label) == 255
      assert renamed_feed_label =~ "… / "

      {:ok, _panel} = Power.update_panel(scope, panel, %{name: String.duplicate("Q", 255)})
      renamed_panel_label = Inventory.get_resource!(scope, feed.resource_id).display_name
      assert String.length(renamed_panel_label) == 255
      assert String.starts_with?(renamed_panel_label, "Q")
      assert renamed_panel_label =~ "… / F"
    end

    test "DC feeds have no phase and AC feeds need one", %{scope: scope, site: site} do
      panel = panel!(scope, site)

      {:ok, dc} =
        Power.create_feed(
          scope,
          panel.id,
          feed_attrs(%{name: "DC1", supply: "dc", voltage: "48"})
        )

      assert dc.phase == nil

      assert {:error, changeset} =
               Power.create_feed(scope, panel.id, feed_attrs(%{name: "A2", phase: nil}))

      assert "is required for AC" in errors_on(changeset).phase
    end

    test "rejects ratings and utilization out of range", %{scope: scope, site: site} do
      panel = panel!(scope, site)

      assert {:error, changeset} =
               Power.create_feed(
                 scope,
                 panel.id,
                 feed_attrs(%{voltage: "0", amperage: "-1", max_utilization: 101})
               )

      errors = errors_on(changeset)
      assert errors.voltage != []
      assert errors.amperage != []
      assert errors.max_utilization != []
    end

    test "a feed's rack must be at the panel's site", %{scope: scope, site: site} do
      panel = panel!(scope, site)
      {:ok, other_site} = DCIM.create_site(scope, %{name: "DC2"}, %{slug: "dc2"})
      {:ok, far_rack} = DCIM.create_rack(scope, %{name: "R9"}, %{site_id: other_site.id})
      {:ok, rack} = DCIM.create_rack(scope, %{name: "R1"}, %{site_id: site.id})

      assert {:error, :rack_not_at_site} =
               Power.create_feed(scope, panel.id, feed_attrs(%{rack_id: far_rack.id}))

      {:ok, feed} = Power.create_feed(scope, panel.id, feed_attrs(%{rack_id: rack.id}))
      assert [%{id: feed_id}] = Power.list_rack_feeds(scope, rack.id)
      assert feed_id == feed.id

      assert {:error, :rack_not_at_site} =
               Power.update_feed(scope, feed, %{rack_id: far_rack.id})
    end

    test "a panel's location must be at its site", %{scope: scope, site: site} do
      {:ok, other_site} = DCIM.create_site(scope, %{name: "DC2"}, %{slug: "dc2"})
      {:ok, far_room} = DCIM.create_location(scope, %{name: "Room"}, %{site_id: other_site.id})

      assert {:error, :location_not_at_site} =
               Power.create_panel(scope, %{site_id: site.id, name: "P", location_id: far_room.id})
    end

    test "feed changes are recorded field by field", %{scope: scope, site: site} do
      panel = panel!(scope, site)
      {:ok, feed} = Power.create_feed(scope, panel.id, feed_attrs(%{}))

      {:ok, updated} = Power.update_feed(scope, feed, %{amperage: "32", side: "b"})
      assert Decimal.equal?(updated.amperage, d("32"))

      fields =
        Renga.Inventory.ChangeEvent
        |> where([event], event.resource_id == ^feed.resource_id and event.kind == "updated")
        |> select([event], event.field)
        |> Renga.Repo.all()
        |> Enum.sort()

      assert fields == ["amperage", "side"]
    end

    test "panel names are unique per site", %{scope: scope, site: site} do
      panel!(scope, site)
      assert {:error, changeset} = Power.create_panel(scope, %{site_id: site.id, name: "PDP-1"})
      assert errors_on(changeset).name != []
    end
  end

  describe "authorization" do
    test "members read power but cannot change it", %{
      organization: organization,
      scope: scope,
      site: site
    } do
      panel = panel!(scope, site)
      member = scope_with_role(organization, "member")

      assert [_panel] = Power.list_panels(member, site.id)
      assert {:error, :forbidden} = Power.create_panel(member, %{site_id: site.id, name: "P2"})
      assert {:error, :forbidden} = Power.create_feed(member, panel.id, feed_attrs(%{}))
    end

    test "another organization's site and panels are out of reach", %{scope: scope, site: site} do
      panel = panel!(scope, site)
      stranger = scope_with_role(organization_fixture(), "admin")

      assert Power.list_panels(stranger, site.id) == []

      assert_raise Ecto.NoResultsError, fn ->
        Power.create_panel(stranger, %{site_id: site.id, name: "X"})
      end

      assert_raise Ecto.NoResultsError, fn ->
        Power.create_feed(stranger, panel.id, feed_attrs(%{}))
      end
    end
  end

  defp d(value), do: Decimal.new(value)
end
