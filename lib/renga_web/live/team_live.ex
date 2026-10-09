defmodule RengaWeb.TeamLive do
  @moduledoc """
  Settings → Teams: the organization's teams and how many resources each
  owns. Owners and admins create, rename, and delete teams in a side panel;
  everyone else reads the list. Deleting a team that owns resources says how
  many will become unowned first.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory.Changes
  alias Renga.Teams
  alias Renga.Teams.Team

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(page_title: "Teams", can_manage?: Teams.can_manage?(scope), editing: nil)
     |> assign_form(%Team{})
     |> load_teams()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign_form(%Team{})}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Teams.get_team(socket.assigns.current_scope, id) do
      nil -> {:noreply, load_teams(socket)}
      team -> {:noreply, socket |> assign(:editing, team) |> assign_form(team)}
    end
  end

  def handle_event("validate", %{"team" => attrs}, socket) do
    form =
      (socket.assigns.editing || %Team{})
      |> Teams.change_team(attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"team" => attrs}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns

    result =
      if editing,
        do: Teams.update_team(scope, editing, attrs),
        else: Teams.create_team(scope, attrs)

    case result do
      {:ok, team} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{team.name} saved")
         |> close_overlay("team-panel")
         |> assign(:editing, nil)
         |> assign_form(%Team{})
         |> load_teams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Managing teams requires the owner or admin role")}

      {:error, :not_found} ->
        {:noreply, socket |> close_overlay("team-panel") |> load_teams()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Team{} = team <- Teams.get_team(scope, id),
         {:ok, _team} <- Teams.delete_team(scope, team) do
      {:noreply, socket |> put_flash(:info, "#{team.name} deleted") |> load_teams()}
    else
      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Managing teams requires the owner or admin role")}

      _gone ->
        {:noreply, load_teams(socket)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_teams(socket)}

  defp load_teams(socket),
    do: assign(socket, :teams, Teams.list_teams(socket.assigns.current_scope))

  defp assign_form(socket, team), do: assign(socket, :form, to_form(Teams.change_team(team)))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:teams}
    >
      <.settings_page
        id="teams"
        title="Teams"
        description="The groups that answer for resources. A resource without an owning team stays in triage until it has one."
      >
        <:actions>
          <.button
            :if={@can_manage?}
            id="new-team"
            variant="primary"
            phx-click={JS.push("new") |> show_overlay("team-panel")}
          >
            New team
          </.button>
        </:actions>

        <.table
          id="team-list"
          rows={@teams}
          row_id={&"team-#{&1.id}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={team} label="Team" class="py-2">
            <span class="block font-medium text-fg">{team.name}</span>
            <span :if={team.description} class="block truncate text-xs text-fg-muted">
              {team.description}
            </span>
          </:col>
          <:col :let={team} label="Owns" class="whitespace-nowrap text-right">
            <.link
              navigate={~p"/inventory?#{[owner: team.id]}"}
              class="font-mono text-xs tabular-nums text-link hover:underline"
            >
              {resource_label(team.resource_count)}
            </.link>
          </:col>
          <:action :let={team} :if={@can_manage?}>
            <button
              id={"team-#{team.id}-edit"}
              type="button"
              phx-click={JS.push("edit", value: %{id: team.id}) |> show_overlay("team-panel")}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Edit
            </button>
            <button
              id={"team-#{team.id}-delete"}
              type="button"
              phx-click={show_overlay("delete-team-#{team.id}")}
              class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
            >
              Delete
            </button>
          </:action>
          <:empty>
            No teams yet. <span :if={@can_manage?}>Create one to start assigning owners.</span>
          </:empty>
        </.table>

        <p :if={!@can_manage?} id="teams-read-only" class="text-sm text-fg-muted">
          Owners and admins manage teams.
        </p>
      </.settings_page>

      <.confirm_dialog
        :for={team <- @teams}
        :if={@can_manage?}
        id={"delete-team-#{team.id}"}
        title={"Delete #{team.name}?"}
        confirm_label="Delete team"
        on_confirm={JS.push("delete", value: %{id: team.id})}
      >
        <%= if team.resource_count > 0 do %>
          {resource_label(team.resource_count)} will have no owner and return to triage.
        <% else %>
          The team owns no resources.
        <% end %>
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage?}
        id="team-panel"
        title={if @editing, do: "Edit #{@editing.name}", else: "New team"}
      >
        <.form for={@form} id="team-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:name]} type="text" label="Name" required autocomplete="off" />
          <.input field={@form[:description]} type="textarea" label="Description" rows="3" />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("team-panel")}>Cancel</.button>
            <.button id="team-save" variant="primary" phx-disable-with="Saving…">Save team</.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp resource_label(1), do: "1 resource"
  defp resource_label(count), do: "#{count} resources"
end
