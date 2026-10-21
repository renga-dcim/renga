defmodule RengaWeb.RoleLive do
  @moduledoc """
  Settings → Roles: the four built-in roles and the organization's custom
  roles, each with the permissions it grants (RFD 17, "Roles"). Holders of
  `roles.manage` define, change, and delete custom roles in a side panel
  that offers only the permissions within their grant ceiling. Everyone
  else reads the list. Renga.Roles re-checks all of it.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

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

  defp refusal(:forbidden),
    do: "That needs roles.manage, and every permission in the role must be one you may grant."

  defp refusal(_reason), do: "That role no longer exists."

  defp load_roles(socket),
    do: assign(socket, :roles, Roles.list_roles(socket.assigns.current_scope))

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
        description="A role is a named set of permissions. Members hold a built-in role; custom roles add combinations of your own."
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
        Nobody can hold it afterwards.
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage?}
        id="role-panel"
        title={if @editing, do: "Edit #{@editing.name}", else: "New role"}
        description="Changing a role changes access for everyone who holds it."
      >
        <.form for={@form} id="role-form" phx-submit="save">
          <.input field={@form[:name]} type="text" label="Name" required autocomplete="off" />
          <.input field={@form[:description]} type="textarea" label="Description" rows="2" />
          <fieldset id="role-permissions" class="mb-3">
            <legend class="mb-1 text-sm font-medium text-fg">Permissions</legend>
            <input type="hidden" name="role[permissions][]" value="" />
            <label
              :for={permission <- Authorization.custom_role_permissions()}
              :if={permission in @grantable}
              class="flex min-h-tap cursor-pointer items-start gap-2 py-1"
            >
              <input
                type="checkbox"
                id={"role-permission-#{permission}"}
                name="role[permissions][]"
                value={permission}
                checked={permission in (@form[:permissions].value || [])}
                class="mt-0.5 size-4 rounded border-edge"
              />
              <span class="min-w-0">
                <span class="block font-mono text-xs text-fg">{permission}</span>
                <span class="block text-xs text-fg-muted">{Authorization.describe(permission)}</span>
              </span>
            </label>
            <p
              :for={message <- Enum.map(@form[:permissions].errors, &translate_error/1)}
              class="mt-1 text-sm text-crit"
            >
              {message}
            </p>
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
end
