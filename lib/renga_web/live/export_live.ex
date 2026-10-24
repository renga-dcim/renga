defmodule RengaWeb.ExportLive do
  @moduledoc """
  Settings → Export: export the whole organization (RFD 20).

  People who hold `organization.export` (owners, unless a custom role grants
  it) start an export, follow it while it runs, download the archive for
  seven days, and revoke a download early. Everyone else sees only who can.
  Every action is rechecked in `Renga.Transfers`; the page only hides what
  would be refused.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Authorization
  alias Renga.Inventory.Changes
  alias Renga.Transfers
  alias Renga.Transfers.OrganizationExport
  alias RengaWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    can_export? = Authorization.allowed?(scope, "organization.export")
    if connected?(socket) and can_export?, do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: "Export",
       can_export?: can_export?,
       validity_days: Transfers.validity_days(),
       form: to_form(%{"history" => "false", "raw_observations" => "false"}, as: :export)
     )
     |> load_exports()}
  end

  @impl true
  def handle_event("start", %{"export" => params}, socket) do
    parts = for {part, "true"} <- params, do: part
    url = url(~p"/settings/export")

    case Transfers.start_export(socket.assigns.current_scope, parts, fn -> url end) do
      {:ok, _export} ->
        {:noreply,
         socket
         |> put_flash(:info, "Export started. We'll email you when it's ready.")
         |> load_exports()}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "An export is already running.")}

      {:error, :forbidden} ->
        {:noreply, forbidden(socket)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Transfers.revoke_export(socket.assigns.current_scope, id) do
      {:ok, _export} ->
        {:noreply,
         socket
         |> close_overlay("revoke-export-#{id}")
         |> put_flash(:info, "Export revoked. Its archive was deleted.")
         |> load_exports()}

      {:error, :not_found} ->
        {:noreply, socket |> close_overlay("revoke-export-#{id}") |> load_exports()}

      {:error, :forbidden} ->
        {:noreply, forbidden(socket)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_exports(socket)}

  # Tests run exports inline, so the ready email is delivered from this
  # process and the test mailer reports it back here.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp forbidden(socket) do
    socket
    |> assign(:can_export?, false)
    |> assign(:exports, [])
    |> put_flash(:error, "You can no longer export this organization.")
  end

  defp load_exports(%{assigns: %{can_export?: false}} = socket), do: assign(socket, :exports, [])

  defp load_exports(socket) do
    case Transfers.list_exports(socket.assigns.current_scope) do
      {:ok, exports} -> assign(socket, :exports, exports)
      {:error, :forbidden} -> forbidden(socket)
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :now, Renga.Time.utc_now_ms())

    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:export}
    >
      <.settings_page
        id="export"
        title="Export"
        description="Take all of the organization's data out of Renga in a documented format, to keep or to import into another deployment."
        class="max-w-4xl"
      >
        <p :if={!@can_export?} id="export-owners-only" class="text-sm text-fg-muted">
          Only organization owners can export the organization.
        </p>

        <.settings_section
          :if={@can_export?}
          id="export-new"
          title="New export"
          description={"The archive covers everything in the organization, whoever can see it, and holds no passwords, keys, or tokens. It can be downloaded for #{@validity_days} days."}
        >
          <.form for={@form} id="export-form" phx-submit="start" class="space-y-3">
            <.input
              field={@form[:history]}
              type="checkbox"
              label="Include history: Activity, revisions, and jobs"
            />
            <.input
              field={@form[:raw_observations]}
              type="checkbox"
              label="Include all raw observations, which can be much larger"
            />
            <.button id="export-start" variant="primary" phx-disable-with="Starting…">
              Export organization
            </.button>
          </.form>
        </.settings_section>

        <.settings_section
          :if={@can_export?}
          id="export-history"
          title="Exports"
          description="Every download checks that you can still export. Revoke an export to delete its archive now."
        >
          <.table
            id="export-list"
            rows={@exports}
            row_id={&"export-#{&1.id}"}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={export} label="Started" class="py-2">
              <span class="block text-sm text-fg">{Format.datetime(export.inserted_at)}</span>
              <span class="block truncate text-xs text-fg-muted">
                {requester(export)}{parts(export)}
              </span>
            </:col>
            <:col :let={export} label="Status" class="whitespace-nowrap">
              <span
                id={"export-#{export.id}-status"}
                data-status={status(export, @now)}
                class={["text-sm", status_class(status(export, @now))]}
              >
                {status_label(export, @now)}
              </span>
            </:col>
            <:col :let={export} label="Size" class="whitespace-nowrap text-right">
              <span :if={export.bytes} class="font-mono text-xs tabular-nums text-fg-muted">
                {size(export.bytes)}
              </span>
            </:col>
            <:action :let={export}>
              <a
                :if={status(export, @now) == "ready"}
                id={"export-#{export.id}-download"}
                href={~p"/settings/export/#{export.id}/download"}
                class="min-h-tap inline-flex items-center text-sm text-link hover:underline"
              >
                Download
              </a>
              <button
                :if={status(export, @now) in ~w(running ready)}
                id={"export-#{export.id}-revoke"}
                type="button"
                phx-click={show_overlay("revoke-export-#{export.id}")}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Revoke
              </button>
            </:action>
            <:empty>No exports yet.</:empty>
          </.table>
        </.settings_section>
      </.settings_page>

      <.confirm_dialog
        :for={export <- @exports}
        :if={status(export, @now) in ~w(running ready)}
        id={"revoke-export-#{export.id}"}
        title="Revoke this export?"
        confirm_label="Revoke export"
        on_confirm={JS.push("revoke", value: %{id: export.id})}
      >
        Its archive is deleted and its download link stops working. Copies already downloaded are not affected.
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  # A ready export past its expiry reads as expired until the sweep catches
  # up.
  defp status(%{status: "ready"} = export, now) do
    if OrganizationExport.downloadable?(export, now), do: "ready", else: "expired"
  end

  defp status(%{status: status}, _now), do: status

  defp status_label(export, now) do
    case status(export, now) do
      "running" -> "Running"
      "ready" -> "Ready until #{Format.datetime(export.expires_at)}"
      "failed" -> "Failed"
      "revoked" -> "Revoked"
      "expired" -> "Expired"
    end
  end

  defp status_class("ready"), do: "text-fg"
  defp status_class("failed"), do: "text-crit"
  defp status_class(_status), do: "text-fg-muted"

  defp requester(%{requested_by_user: %{email: email}}), do: email
  defp requester(_export), do: "Someone no longer here"

  defp parts(%{parts: []}), do: ""
  defp parts(%{parts: parts}), do: " · with " <> Enum.map_join(parts, " and ", &part/1)

  defp part("history"), do: "history"
  defp part("raw_observations"), do: "raw observations"

  defp size(bytes) when bytes < 1024 * 1024, do: "#{max(div(bytes, 1024), 1)} KB"

  defp size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
