defmodule RengaWeb.UITest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import RengaWeb.CoreComponents
  import RengaWeb.UI

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.JS

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp present?(html, selector), do: LazyHTML.to_html(query(html, selector)) != ""
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> squish()
  defp attr_of(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)
  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  describe "status_strip/1" do
    test "renders the four signals in their fixed order" do
      html =
        render_component(&status_strip/1,
          lifecycle: "active",
          freshness: :current,
          freshness_label: "1m",
          agent: :connected,
          drift: 2
        )

      assert attr_of(html, "[data-signal]", "data-signal") ==
               ["lifecycle", "freshness", "agent", "drift"]

      assert text(html, "[data-signal='lifecycle']") == "Lifecycle: Active"
      assert text(html, "[data-signal='freshness']") == "Inventory: 1m"
      assert text(html, "[data-signal='agent']") == "Agent: Agent"
      assert text(html, "[data-signal='drift']") =~ "2 drift findings"
    end

    test "omits drift when nothing drifted and names missing signals" do
      html = render_component(&status_strip/1, [])

      refute present?(html, "[data-signal='drift']")
      assert text(html, "[data-signal='lifecycle']") == "Lifecycle: Unknown"
      assert text(html, "[data-signal='freshness']") == "Inventory: Unknown"
      assert text(html, "[data-signal='agent']") == "Agent: No agent"
    end

    test "marks stale inventory and lost agents with their status colors" do
      html = render_component(&status_strip/1, freshness: :stale, agent: :lost)

      assert present?(html, "[data-signal='freshness'] .text-warn-text")
      assert present?(html, "[data-signal='agent'] .border-crit")
      assert text(html, "[data-signal='agent']") == "Agent: Agent lost"
    end
  end

  describe "table/1" do
    test "shows the empty state, which CSS hides once rows exist" do
      assigns = %{rows: []}

      html =
        rendered_to_string(~H"""
        <.table id="items" rows={@rows}>
          <:col :let={item} label="Name">{item.name}</:col>
          <:empty>Nothing here yet.</:empty>
        </.table>
        """)

      assert text(html, "#items-empty") == "Nothing here yet."
      assert attr_of(html, "#items-empty", "class") == ["hidden only:table-row"]
      assert attr_of(html, "#items-empty td", "colspan") == ["1"]
    end

    test "marks the selected row and navigates from any cell" do
      assigns = %{rows: [%{id: 1, name: "compute-01"}, %{id: 2, name: "compute-02"}]}

      html =
        rendered_to_string(~H"""
        <.table
          id="items"
          rows={@rows}
          row_id={&"item-#{&1.id}"}
          row_navigate={&"/inventory/resources/#{&1.id}"}
          row_selected={&(&1.id == 2)}
        >
          <:col :let={item} label="Name" class="font-medium">{item.name}</:col>
        </.table>
        """)

      assert attr_of(html, "#item-2", "aria-current") == ["true"]
      refute present?(html, "#item-1[aria-current]")
      assert [click] = attr_of(html, "#item-1 td", "phx-click")
      assert click =~ "/inventory/resources/1"
      assert present?(html, "#item-1 td.font-medium")
      assert present?(html, "thead th[scope='col'].font-medium")
    end
  end

  describe "object_page/1" do
    test "renders the title, tabs as navigation, and the properties aside" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.object_page id="resource" title="Primary compute node" subtitle="compute-01 · server">
          <:breadcrumb>Inventory</:breadcrumb>
          <:status><.status_strip size="header" lifecycle="active" /></:status>
          <:tab patch="/inventory/resources/1" active>Overview</:tab>
          <:tab patch="/inventory/resources/1/hardware" count={2}>Hardware</:tab>
          <p id="overview-body">Overview content</p>
          <:aside>
            <.properties>
              <:item label="Owner">Platform</:item>
            </.properties>
          </:aside>
        </.object_page>
        """)

      assert text(html, "#resource h1") == "Primary compute node"
      assert text(html, "nav[aria-label='Breadcrumb']") == "Inventory"
      assert present?(html, "#resource [role='group'][aria-label='Status']")

      assert attr_of(html, "#resource-tabs a", "href") == [
               "/inventory/resources/1",
               "/inventory/resources/1/hardware"
             ]

      assert text(html, "#resource-tabs a[aria-current='page']") == "Overview"
      assert text(html, "#resource-tabs a:last-child") == "Hardware 2"
      assert present?(html, "#overview-body")
      assert present?(html, "aside[aria-label='Details'] dl")
    end
  end

  describe "properties/1" do
    test "editable items are buttons whose accessible name includes the property" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.properties id="props">
          <:item label="Lifecycle" on_edit={JS.push("edit_lifecycle")}>Active</:item>
          <:item label="Warranty" blank placeholder="Add end date" on_edit="edit_warranty" />
          <:item label="Serial">DEMO-COMP-001</:item>
        </.properties>
        """)

      assert text(html, "#props h2") == "Properties"
      assert text(html, "#props dl > div:nth-child(1) button") == "Edit Lifecycle: Active"
      assert [click] = attr_of(html, "#props dl > div:nth-child(1) button", "phx-click")
      assert click =~ "edit_lifecycle"

      assert text(html, "#props dl > div:nth-child(2) button") ==
               "Edit Warranty: Add end date"

      refute present?(html, "#props dl > div:nth-child(3) button")
      assert text(html, "#props dl > div:nth-child(3) dd") == "DEMO-COMP-001"
    end
  end

  describe "side_panel/1" do
    test "is a labelled modal dialog that starts hidden" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.side_panel id="new-vlan" title="New VLAN" description="VLAN IDs are unique per group.">
          <p>Form</p>
          <:footer><.button variant="primary">Create VLAN</.button></:footer>
        </.side_panel>
        """)

      assert attr_of(html, "#new-vlan", "class") == ["relative z-50 hidden"]
      assert attr_of(html, "#new-vlan-container", "role") == ["dialog"]
      assert attr_of(html, "#new-vlan-container", "aria-modal") == ["true"]
      assert attr_of(html, "#new-vlan-container", "aria-labelledby") == ["new-vlan-title"]
      assert attr_of(html, "#new-vlan-container", "aria-describedby") == ["new-vlan-description"]
      assert text(html, "#new-vlan-title") == "New VLAN"
      assert present?(html, "#new-vlan footer button.bg-accent")
      assert present?(html, "#new-vlan button[aria-label='Close']")
    end

    test "opens on mount when shown" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.side_panel id="edit" title="Edit" show>Body</.side_panel>
        """)

      assert [mounted] = attr_of(html, "#edit", "phx-mounted")
      assert mounted =~ "#edit-container"
    end
  end

  describe "confirm_dialog/1" do
    test "pushes the confirm event, closes, and styles destruction as danger" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.confirm_dialog id="revoke" title="Revoke key?" confirm_label="Revoke" on_confirm="revoke">
          Collectors stop reporting.
        </.confirm_dialog>
        """)

      assert attr_of(html, "#revoke-container", "role") == ["alertdialog"]
      assert attr_of(html, "#revoke-container", "aria-describedby") == ["revoke-message"]
      assert text(html, "#revoke-message") == "Collectors stop reporting."
      assert text(html, "#revoke-confirm") == "Revoke"
      assert present?(html, "#revoke-confirm.bg-crit")
      assert [click] = attr_of(html, "#revoke-confirm", "phx-click")
      assert click =~ ~s("revoke")
      assert click =~ "#revoke-container"
      assert text(html, "#revoke-cancel") == "Cancel"
    end
  end

  describe "overlay commands" do
    test "show and hide target the overlay, its backdrop, and its container" do
      shown = show_overlay("panel") |> Safe.to_iodata() |> IO.iodata_to_binary()
      hidden = hide_overlay("panel") |> Safe.to_iodata() |> IO.iodata_to_binary()

      for selector <- ["#panel", "#panel-backdrop", "#panel-container"] do
        assert shown =~ selector
        assert hidden =~ selector
      end

      assert shown =~ "push_focus"
      assert shown =~ "focus_first"
      assert hidden =~ "pop_focus"
    end
  end
end
