defmodule RengaWeb.RoleLive do
  @moduledoc """
  Settings → Roles: the four built-in roles and the organization's custom
  roles, each with the permissions it grants (RFD 17, "Roles"). Holders of
  `roles.manage` define, change, and delete custom roles in a side panel
  that offers only the permissions within their grant ceiling. Each role
  shows how many people hold it, so a change's reach is visible before it
  is saved. Everyone else reads the list. Renga.Roles re-checks all of it.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Accounts
  alias Renga.Assignments
  alias Renga.Authorization
  alias Renga.Inventory.Changes
  alias Renga.Roles
  alias Renga.Roles.Role

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: "Roles",
       can_manage?: Roles.can_manage?(scope),
       grantable: Roles.grantable_permissions(scope),
       expiry_timer: nil,
       editing: nil
     )
     |> assign_form(%Role{})
     |> load_roles()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign_form(%Role{})}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Roles.get_role(socket.assigns.current_scope, id) do
      nil -> {:noreply, load_roles(socket)}
      role -> {:noreply, socket |> assign(:editing, role) |> assign_form(role)}
    end
  end

  def handle_event("save", %{"role" => attrs}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns
    attrs = Map.update(attrs, "permissions", [], &List.wrap/1)

    result =
      if editing,
        do: Roles.update_role(scope, editing, attrs),
        else: Roles.create_role(scope, attrs)

    case result do
      {:ok, role} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{role.name} saved")
         |> close_overlay("role-panel")
         |> assign(:editing, nil)
         |> assign_form(%Role{})
         |> load_roles()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load_roles()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Role{} = role <- Roles.get_role(scope, id),
         {:ok, _role} <- Roles.delete_role(scope, role) do
      {:noreply, socket |> put_flash(:info, "#{role.name} deleted") |> load_roles()}
    else
      {:error, reason} -> {:noreply, socket |> put_flash(:error, refusal(reason)) |> load_roles()}
      nil -> {:noreply, load_roles(socket)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_roles(socket)}

  def handle_info(:assignment_expiry, socket),
    do: {:noreply, socket |> assign(:expiry_timer, nil) |> load_roles()}

  defp refusal(:forbidden),
    do: "That needs roles.manage, and every permission in the role must be one you may grant."

  defp refusal(_reason), do: "That role no longer exists."

  defp load_roles(socket) do
    previous = socket.assigns.current_scope
    scope = Accounts.scope_for_user(previous.user, previous.organization_id)

    if scope.organization_id == previous.organization_id do
      can_manage? = Roles.can_manage?(scope)
      roles = Roles.list_roles(scope)
      editing = selected(socket.assigns.editing, roles, can_manage?)

      socket
      |> assign(
        current_scope: scope,
        can_manage?: can_manage?,
        grantable: Roles.grantable_permissions(scope),
        roles: roles,
        usage: Assignments.role_usage(scope),
        editing: editing
      )
      |> reset_deleted_editor(socket.assigns.editing, editing)
      |> schedule_expiry(scope)
    else
      push_navigate(socket, to: ~p"/organizations")
    end
  end

  defp selected(_editing, _roles, false), do: nil
  defp selected(nil, _roles, true), do: nil
  defp selected(editing, roles, true), do: Enum.find(roles, &(&1.id == editing.id))

  defp reset_deleted_editor(socket, %Role{}, nil),
    do: socket |> close_overlay("role-panel") |> assign_form(%Role{})

  defp reset_deleted_editor(socket, _previous, _editing), do: socket

  defp schedule_expiry(socket, scope) do
    if socket.assigns.expiry_timer, do: Process.cancel_timer(socket.assigns.expiry_timer)

    timer =
      if connected?(socket) do
        case Assignments.next_expiry(scope) do
          nil ->
            nil

          deadline ->
            delay =
              deadline
              |> DateTime.diff(Renga.Time.utc_now_ms(), :millisecond)
              |> max(1)
              |> min(2_147_483_647)

            Process.send_after(self(), :assignment_expiry, delay)
        end
      end

    assign(socket, :expiry_timer, timer)
  end

  defp people(usage, role) do
    case Map.get(usage, role.id) do
      nil -> "Nobody"
      %{people: 1} -> "1 person"
      %{people: people} -> "#{people} people"
    end
  end

  defp assign_form(socket, role), do: assign(socket, :form, to_form(Roles.change_role(role)))

  defp built_in_roles do
    for role <- Authorization.built_in_roles(),
        do: %{name: role, permissions: Authorization.role_permissions(role)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, built_in: built_in_roles())

    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:roles}
    >
      <.settings_page
        id="roles"
        title="Roles"
        description="Roles grant permissions across the whole organization, not individual resources, sites, teams, or groups. Members hold a built-in role; custom roles add permissions."
      >
        <:actions>
          <.button
            :if={@can_manage?}
            id="new-role"
            variant="primary"
            phx-click={JS.push("new") |> show_overlay("role-panel")}
          >
            New role
          </.button>
        </:actions>

        <section id="custom-roles" class="space-y-2">
          <h2 class="text-sm font-medium text-fg">Custom roles</h2>
          <.table
            id="role-list"
            rows={@roles}
            row_id={&"role-#{&1.id}"}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={role} label="Role" class="py-2">
              <span class="block font-medium text-fg">{role.name}</span>
              <span :if={role.description} class="block truncate text-xs text-fg-muted">
                {role.description}
              </span>
            </:col>
            <:col :let={role} label="Permissions">
              <span class="font-mono text-xs text-fg-muted">
                {Enum.join(role.permissions, ", ")}
              </span>
            </:col>
            <:col :let={role} label="Held by" class="w-28">
              <span id={"role-#{role.id}-people"} class="text-sm text-fg-muted">
                {people(@usage, role)}
              </span>
            </:col>
            <:action :let={role} :if={@can_manage?}>
              <button
                id={"role-#{role.id}-edit"}
                type="button"
                phx-click={JS.push("edit", value: %{id: role.id}) |> show_overlay("role-panel")}
                class="min-h-tap cursor-pointer text-sm text-link hover:underline"
              >
                Edit
              </button>
              <button
                id={"role-#{role.id}-delete"}
                type="button"
                phx-click={show_overlay("delete-role-#{role.id}")}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Delete
              </button>
            </:action>
            <:empty>
              No custom roles yet.
              <span :if={@can_manage?}>Combine permissions into one for a job the built-in roles don't fit.</span>
            </:empty>
          </.table>
        </section>

        <section id="built-in-roles" class="space-y-2">
          <h2 class="text-sm font-medium text-fg">Built-in roles</h2>
          <.table
            id="built-in-role-list"
            rows={@built_in}
            row_id={&"built-in-role-#{&1.name}"}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={role} label="Role" class="w-28 py-2">
              <span class="font-medium capitalize text-fg">{role.name}</span>
            </:col>
            <:col :let={role} label="Permissions">
              <span class="font-mono text-xs text-fg-muted">
                {Enum.join(role.permissions, ", ")}
              </span>
            </:col>
          </.table>
        </section>
      </.settings_page>

      <.confirm_dialog
        :for={role <- @roles}
        :if={@can_manage?}
        id={"delete-role-#{role.id}"}
        title={"Delete #{role.name}?"}
        confirm_label="Delete role"
        on_confirm={JS.push("delete", value: %{id: role.id})}
      >
        {people(@usage, role)} with it will lose it, and nobody can hold it afterwards.
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage?}
        id="role-panel"
        title={if @editing, do: "Edit #{@editing.name}", else: "New role"}
        description={
          if @editing,
            do:
              "Changing this role changes access for #{String.downcase(people(@usage, @editing))} who hold it.",
            else: "Give it to people from Settings → Members."
        }
      >
        <.form for={@form} id="role-form" phx-submit="save">
          <.input field={@form[:name]} type="text" label="Name" required autocomplete="off" />
          <.input field={@form[:description]} type="textarea" label="Description" rows="2" />
          <fieldset id="role-permissions" class="mb-3">
            <legend class="mb-1 text-sm font-medium text-fg">Permissions</legend>
            <input type="hidden" name="role[permissions][]" value="" />
            <.permission_option
              :for={permission <- Authorization.custom_role_permissions()}
              :if={permission in @grantable and not Authorization.explicit?(permission)}
              permission={permission}
              checked={permission in (@form[:permissions].value || [])}
            />
            <p
              :for={message <- Enum.map(@form[:permissions].errors, &translate_error/1)}
              class="mt-1 text-sm text-crit"
            >
              {message}
            </p>
          </fieldset>
          <fieldset
            :if={Enum.any?(Authorization.explicit_permissions(), &(&1 in @grantable))}
            id="role-explicit-permissions"
            class="mb-3"
          >
            <legend class="mb-1 text-sm font-medium text-fg">Operational access</legend>
            <p class="mb-1 text-xs text-fg-muted">
              Explicit permissions. No built-in role includes them, and a role with one holds nothing else.
            </p>
            <.permission_option
              :for={permission <- Authorization.explicit_permissions()}
              :if={permission in @grantable}
              permission={permission}
              checked={permission in (@form[:permissions].value || [])}
            />
          </fieldset>
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("role-panel")}>Cancel</.button>
            <.button id="role-save" variant="primary" phx-disable-with="Saving…">Save role</.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :permission, :string, required: true
  attr :checked, :boolean, default: false

  defp permission_option(assigns) do
    ~H"""
    <label class="flex min-h-tap cursor-pointer items-start gap-2 py-1">
      <input
        type="checkbox"
        id={"role-permission-#{@permission}"}
        name="role[permissions][]"
        value={@permission}
        checked={@checked}
        class="mt-0.5 size-4 rounded border-edge"
      />
      <span class="min-w-0">
        <span class="block font-mono text-xs text-fg">{@permission}</span>
        <span class="block text-xs text-fg-muted">{Authorization.describe(@permission)}</span>
      </span>
    </label>
    """
  end
end
