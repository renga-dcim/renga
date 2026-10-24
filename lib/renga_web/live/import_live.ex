defmodule RengaWeb.ImportLive do
  @moduledoc """
  Settings → Import: settings an import held for an owner (RFD 20).

  An import applies source settings only where they do not weaken this
  organization; the rest wait here. People who hold `organization.manage`
  confirm each one, which applies it as if they had changed it themselves,
  or dismiss it. Everyone else sees only who can. Every action is rechecked
  in `Renga.Transfers.HeldSettings`.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Authorization
  alias Renga.Inventory.Changes
  alias Renga.Transfers.HeldSettings
  alias RengaWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    can_manage? = Authorization.allowed?(scope, "organization.manage")
    if connected?(socket) and can_manage?, do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(page_title: "Import", can_manage?: can_manage?)
     |> load_imports()}
  end

  @impl true
  def handle_event("confirm", %{"import" => import_id, "key" => key, "dom" => dom}, socket) do
    socket = close_overlay(socket, "confirm-#{dom}")

    case HeldSettings.confirm(socket.assigns.current_scope, import_id, key) do
      {:ok, item} ->
        {:noreply, socket |> put_flash(:info, "Applied: #{item.label}.") |> load_imports()}

      {:error, :forbidden} ->
        {:noreply, forbidden(socket)}

      {:error, :not_found} ->
        {:noreply, load_imports(socket)}

      {:error, _reason} ->
        {:noreply,
         socket |> put_flash(:error, "This setting could not be applied.") |> load_imports()}
    end
  end

  def handle_event("dismiss", %{"import" => import_id, "key" => key}, socket) do
    case HeldSettings.dismiss(socket.assigns.current_scope, import_id, key) do
      {:ok, item} ->
        {:noreply, socket |> put_flash(:info, "Dismissed: #{item.label}.") |> load_imports()}

      {:error, :forbidden} ->
        {:noreply, forbidden(socket)}

      {:error, :not_found} ->
        {:noreply, load_imports(socket)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_imports(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp forbidden(socket) do
    socket
    |> assign(can_manage?: false, imports: [])
    |> put_flash(:error, "You can no longer change this organization's settings.")
  end

  defp load_imports(%{assigns: %{can_manage?: false}} = socket), do: assign(socket, :imports, [])

  defp load_imports(socket) do
    case HeldSettings.list(socket.assigns.current_scope) do
      {:ok, imports} ->
        imports =
          for {import, items} <- imports do
            items = Enum.with_index(items, &Map.put(&1, :dom, "held-#{import.id}-#{&2}"))
            {import, items}
          end

        assign(socket, :imports, imports)

      {:error, :forbidden} ->
        forbidden(socket)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:import}
    >
      <.settings_page
        id="import"
        title="Import"
        description="Settings an import held back because they would weaken this organization's. Confirm each one to apply it, or dismiss it."
        class="max-w-4xl"
      >
        <p :if={!@can_manage?} id="import-owners-only" class="text-sm text-fg-muted">
          Only people who can change organization settings see what an import held.
        </p>

        <p :if={@can_manage? and @imports == []} id="import-none" class="text-sm text-fg-muted">
          No imported settings are waiting to be confirmed.
        </p>

        <.settings_section
          :for={{import, items} <- @imports}
          id={"import-#{import.id}"}
          title={"From #{import.source_name}"}
          description={"Exported from #{import.source_slug} on #{Format.datetime(import.snapshot_at)} and imported on #{Format.datetime(import.inserted_at)}."}
        >
          <ul class="divide-y divide-edge rounded-lg border border-edge bg-surface">
            <li
              :for={item <- items}
              id={item.dom}
              class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
            >
              <span class="min-w-0">
                <span class="block text-sm text-fg">{item.label}</span>
                <span :if={!item.applied?} class="block text-xs text-fg-muted">
                  This version of Renga cannot apply it.
                </span>
              </span>
              <span class="flex items-center gap-4">
                <button
                  :if={item.applied?}
                  id={"#{item.dom}-confirm"}
                  type="button"
                  phx-click={show_overlay("confirm-#{item.dom}")}
                  class="min-h-tap cursor-pointer text-sm text-link hover:underline"
                >
                  Confirm
                </button>
                <button
                  id={"#{item.dom}-dismiss"}
                  type="button"
                  phx-click={JS.push("dismiss", value: %{import: import.id, key: item.key})}
                  class="min-h-tap cursor-pointer text-sm text-fg-muted hover:underline"
                >
                  Dismiss
                </button>
              </span>
            </li>
          </ul>
        </.settings_section>
      </.settings_page>

      <%= for {import, items} <- @imports, item <- items, item.applied? do %>
        <.confirm_dialog
          id={"confirm-#{item.dom}"}
          title="Apply this setting?"
          confirm_label="Apply setting"
          on_confirm={JS.push("confirm", value: %{import: import.id, key: item.key, dom: item.dom})}
        >
          {item.label}. This weakens what the organization had before the import, and is recorded in Activity as your change.
        </.confirm_dialog>
      <% end %>
    </Layouts.app>
    """
  end
end
