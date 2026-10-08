defmodule RengaWeb.UIReviewLive do
  @moduledoc false
  use RengaWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_scope, nil)
     |> assign(:cancelled, "none")
     |> assign(:confirmed, 0)
     |> stream(:items, [%{id: 1, name: "Compute node"}])}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl space-y-6 p-6">
        <h1 class="text-xl font-semibold text-fg">Shared component regression fixture</h1>
        <div class="flex gap-3">
          <.button id="open-panel" phx-click={show_overlay("panel")}>Edit node</.button>
          <.button id="open-dialog" phx-click={show_overlay("dialog")}>Confirm change</.button>
          <.button id="primary" variant="primary">Primary action</.button>
        </div>
        <p id="cancelled">{@cancelled}</p>
        <p id="confirmed">{@confirmed}</p>
        <.table id="items" rows={@streams.items} row_navigate={fn {_id, _item} -> "/users/log-in" end}>
          <:col :let={{_id, item}} label="Name">{item.name}</:col>
          <:col :let={{_id, item}} label="ID">{item.id}</:col>
          <:empty>No nodes.</:empty>
        </.table>
        <.button id="add" phx-click="add">Add row</.button>
        <.button id="delete" phx-click="delete">Delete row</.button>
        <.button id="reset" phx-click="reset">Reset rows</.button>
        <.side_panel
          id="panel"
          title="Edit node"
          on_cancel={JS.push("cancel", value: %{name: "panel"})}
        >
          <.input id="node-name" name="name" label="Name" value="Compute node" />
          <:footer>
            <.button variant="primary" phx-click={hide_overlay("panel")}>Save</.button>
          </:footer>
        </.side_panel>
        <.confirm_dialog
          id="dialog"
          title="Confirm change?"
          on_confirm="confirm"
          on_cancel={JS.push("cancel", value: %{name: "dialog"})}
        >
          Apply the change to this node.
        </.confirm_dialog>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("cancel", %{"name" => name}, socket),
    do: {:noreply, assign(socket, :cancelled, name)}

  def handle_event("confirm", _, socket), do: {:noreply, update(socket, :confirmed, &(&1 + 1))}

  def handle_event("add", _, socket),
    do: {:noreply, stream_insert(socket, :items, %{id: 2, name: "Second node"})}

  def handle_event("delete", _, socket), do: {:noreply, stream_delete(socket, :items, %{id: 1})}
  def handle_event("reset", _, socket), do: {:noreply, stream(socket, :items, [], reset: true)}
end
