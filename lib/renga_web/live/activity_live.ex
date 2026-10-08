defmodule RengaWeb.ActivityLive do
  @moduledoc """
  The organization-wide Activity feed (RFD 8: "What changed?").

  It starts with the inventory change events reconciliation already records:
  discoveries, field updates, conflicts, staleness, and overrides. Later
  phases add people's actions to the same feed rather than new pages.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.Changes

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Changes.subscribe(socket.assigns.current_scope)
    events = Inventory.list_activity(socket.assigns.current_scope, limit: @page_size)

    {:ok,
     socket
     |> assign(page_title: "Activity")
     |> assign_page(events)
     |> stream(:events, events)}
  end

  # Observation time is not insertion time: refresh the whole displayed
  # window so late reports and bursts cannot leave permanent gaps.
  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    events =
      Inventory.list_activity(socket.assigns.current_scope,
        since: if(socket.assigns.more?, do: socket.assigns.oldest),
        limit: nil
      )

    {:noreply,
     socket
     |> assign(:oldest, List.last(events))
     |> stream(:events, events, reset: true)}
  end

  @impl true
  def handle_event("load_older", _params, socket) do
    events =
      Inventory.list_activity(socket.assigns.current_scope,
        before: socket.assigns.oldest,
        limit: @page_size
      )

    {:noreply, socket |> assign_page(events) |> stream(:events, events)}
  end

  # Keep only the cursor, not the rows: the stream owns what is on screen.
  defp assign_page(socket, events) do
    assign(socket,
      oldest: List.last(events) || socket.assigns[:oldest],
      more?: length(events) == @page_size
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:activity}
    >
      <div id="activity" class="mx-auto max-w-5xl space-y-6">
        <.header>
          Activity
          <:subtitle>
            Changes across this organization, newest first. Each resource also keeps its own history.
          </:subtitle>
        </.header>

        <.table id="activity-events" rows={@streams.events} row_item={fn {_id, event} -> event end}>
          <:col :let={event} label="When" class="whitespace-nowrap text-fg-muted">
            <time datetime={DateTime.to_iso8601(event.occurred_at)}>
              {Calendar.strftime(event.occurred_at, "%Y-%m-%d %H:%M UTC")}
            </time>
          </:col>
          <:col :let={event} label="Change" class="font-medium">{describe(event)}</:col>
          <:col :let={event} label="Resource">
            <.link
              :if={event.resource}
              navigate={~p"/inventory/#{event.resource}"}
              class="text-link hover:underline"
            >
              {event.resource.name}
            </.link>
            <span :if={is_nil(event.resource)} class="text-fg-subtle">—</span>
          </:col>
          <:col :let={event} label="Source" class="text-fg-muted">
            {(event.source && event.source.name) || "Renga"}
          </:col>
          <:empty>
            Nothing has changed yet. Changes appear here as collectors report and people edit.
          </:empty>
        </.table>

        <div :if={@more?} class="flex justify-center">
          <.button id="activity-load-older" phx-click="load_older">Load older changes</.button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Field names come from the reconciler (for example "lifecycle_state"); the
  # feed shows them as words so a change reads as a sentence.
  defp describe(%{kind: "discovered"}), do: "Discovered"
  defp describe(%{kind: "stale"}), do: "Marked stale"
  defp describe(%{kind: "updated", field: field}), do: with_field("Updated", field)
  defp describe(%{kind: "conflict", field: field}), do: with_field("Conflict on", field)

  defp describe(%{kind: "manual_override", field: field}),
    do: with_field("Override set on", field)

  defp describe(%{kind: "override_removed", field: field}),
    do: with_field("Override removed from", field)

  defp describe(%{kind: kind}), do: String.capitalize(String.replace(kind, "_", " "))

  defp with_field(verb, nil), do: verb
  defp with_field(verb, field), do: "#{verb} #{String.replace(field, "_", " ")}"
end
