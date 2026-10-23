defmodule RengaWeb.GroupLive do
  @moduledoc """
  Settings → Groups: the organization's resource groups and group sets
  (RFD 18). Holders of `groups.manage` define groups and sets in side
  panels; a group's panel also lists its direct members, which people with
  `inventory.edit` can remove. Everyone else reads the groups they can see:
  the ones with a member they can read.

  A change that would put a resource in two groups of an exclusive set is
  refused, and the flash names the resource and the groups.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  import RengaWeb.GroupComponents

  alias Renga.Inventory.Changes
  alias Renga.ResourceGroups
  alias Renga.ResourceGroups.Group
  alias Renga.ResourceGroups.GroupSet

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: "Groups",
       can_manage?: ResourceGroups.can_manage?(scope),
       can_change_membership?: ResourceGroups.can_change_membership?(scope),
       editing: nil,
       editing_set: nil,
       members: []
     )
     |> assign_form(%Group{})
     |> assign_set_form(%GroupSet{})
     |> load()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(editing: nil, members: []) |> assign_form(%Group{})}
  end

  def handle_event("new_set", _params, socket) do
    {:noreply, socket |> assign(:editing_set, nil) |> assign_set_form(%GroupSet{})}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case ResourceGroups.get_group(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, load(socket)}

      group ->
        {:noreply, socket |> assign(:editing, group) |> assign_form(group) |> load_members()}
    end
  end

  def handle_event("edit_set", %{"id" => id}, socket) do
    case ResourceGroups.get_group_set(socket.assigns.current_scope, id) do
      nil -> {:noreply, load(socket)}
      set -> {:noreply, socket |> assign(:editing_set, set) |> assign_set_form(set)}
    end
  end

  def handle_event("validate", %{"group" => attrs}, socket) do
    form =
      (socket.assigns.editing || %Group{})
      |> ResourceGroups.change_group(attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("validate_set", %{"group_set" => attrs}, socket) do
    form =
      (socket.assigns.editing_set || %GroupSet{})
      |> ResourceGroups.change_group_set(attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :set_form, form)}
  end

  def handle_event("save", %{"group" => attrs}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns

    result =
      if editing,
        do: ResourceGroups.update_group(scope, editing, attrs),
        else: ResourceGroups.create_group(scope, attrs)

    case result do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{group.name} saved")
         |> close_overlay("group-panel")
         |> assign(editing: nil, members: [])
         |> assign_form(%Group{})
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load()}
    end
  end

  def handle_event("save_set", %{"group_set" => attrs}, socket) do
    %{current_scope: scope, editing_set: editing} = socket.assigns

    result =
      if editing,
        do: ResourceGroups.update_group_set(scope, editing, attrs),
        else: ResourceGroups.create_group_set(scope, attrs)

    case result do
      {:ok, set} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{set.name} saved")
         |> close_overlay("group-set-panel")
         |> assign(:editing_set, nil)
         |> assign_set_form(%GroupSet{})
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :set_form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Group{} = group <- ResourceGroups.get_group(scope, id),
         {:ok, _group} <- ResourceGroups.delete_group(scope, group) do
      {:noreply, socket |> put_flash(:info, "#{group.name} deleted") |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      nil -> {:noreply, load(socket)}
    end
  end

  def handle_event("delete_set", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %GroupSet{} = set <- ResourceGroups.get_group_set(scope, id),
         {:ok, _set} <- ResourceGroups.delete_group_set(scope, set) do
      {:noreply, socket |> put_flash(:info, "#{set.name} deleted") |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
      nil -> {:noreply, load(socket)}
    end
  end

  def handle_event(
        "remove_member",
        %{"id" => resource_id, "group_id" => group_id},
        %{
          assigns: %{
            current_scope: scope,
            editing: %Group{id: group_id} = group
          }
        } = socket
      ) do
    case ResourceGroups.remove_members(scope, group, [resource_id]) do
      {:ok, _count} -> {:noreply, socket |> load_members() |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("remove_member", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Choose the group again before removing members")
     |> load()}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, socket |> load() |> load_members()}

  defp refusal(:forbidden), do: "Managing groups requires the owner or admin role"
  defp refusal(reason), do: refusal_message(reason)

  defp load(socket) do
    scope = socket.assigns.current_scope
    groups = ResourceGroups.list_groups(scope)
    sets = ResourceGroups.list_group_sets(scope)
    counts = Enum.frequencies_by(groups, & &1.group_set_id)

    assign(socket,
      groups: groups,
      sets: Enum.map(sets, &{&1, Map.get(counts, &1.id, 0)}),
      set_options: Enum.map(sets, &{set_label(&1), &1.id})
    )
  end

  defp load_members(%{assigns: %{editing: %Group{} = group, current_scope: scope}} = socket),
    do: assign(socket, :members, ResourceGroups.list_members(scope, group))

  defp load_members(socket), do: assign(socket, :members, [])

  defp assign_form(socket, group),
    do: assign(socket, :form, to_form(ResourceGroups.change_group(group)))

  defp assign_set_form(socket, set),
    do: assign(socket, :set_form, to_form(ResourceGroups.change_group_set(set)))

  defp set_label(%GroupSet{name: name, exclusive: true}), do: "#{name} (exclusive)"
  defp set_label(%GroupSet{name: name}), do: name

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:groups}
    >
      <.settings_page
        id="groups"
        title="Groups"
        description="Named sets of resources that cut across sites and teams, such as an environment or a customer. Only people change who is in a group."
      >
        <:actions>
          <.button
            :if={@can_manage?}
            id="new-group-set"
            phx-click={JS.push("new_set") |> show_overlay("group-set-panel")}
          >
            New set
          </.button>
          <.button
            :if={@can_manage?}
            id="new-group"
            variant="primary"
            phx-click={JS.push("new") |> show_overlay("group-panel")}
          >
            New group
          </.button>
        </:actions>

        <.table
          id="group-list"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={group} label="Group" class="py-2">
            <span class="block font-medium text-fg">{group.name}</span>
            <span :if={group.description} class="block truncate text-xs text-fg-muted">
              {group.description}
            </span>
          </:col>
          <:col :let={group} label="Set">
            <.group_set_label set={group.group_set} />
          </:col>
          <:col :let={group} label="Members" class="whitespace-nowrap text-right">
            <span class="font-mono text-xs tabular-nums text-fg-muted">{group.member_count}</span>
          </:col>
          <:action :let={group} :if={@can_manage?}>
            <button
              id={"group-#{group.id}-edit"}
              type="button"
              phx-click={JS.push("edit", value: %{id: group.id}) |> show_overlay("group-panel")}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Edit
            </button>
            <button
              id={"group-#{group.id}-delete"}
              type="button"
              phx-click={show_overlay("delete-group-#{group.id}")}
              class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
            >
              Delete
            </button>
          </:action>
          <:empty>
            No groups yet.
            <span :if={@can_manage?}>Create one, such as Production or a customer.</span>
          </:empty>
        </.table>

        <.settings_section
          :if={@sets != [] or @can_manage?}
          id="group-sets"
          title="Group sets"
          description="A set gathers related groups, such as Environment. In an exclusive set a resource belongs to at most one group."
        >
          <.table
            id="group-set-list"
            rows={@sets}
            row_id={fn {set, _count} -> "group-set-#{set.id}" end}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={{set, _count}} label="Set" class="py-2">
              <span class="block font-medium text-fg">{set.name}</span>
              <span :if={set.description} class="block truncate text-xs text-fg-muted">
                {set.description}
              </span>
            </:col>
            <:col :let={{set, _count}} label="Exclusive">
              <span :if={set.exclusive} class="text-sm text-fg">Yes</span>
              <span :if={!set.exclusive} class="text-sm text-fg-subtle">No</span>
            </:col>
            <:col :let={{_set, count}} label="Groups" class="whitespace-nowrap text-right">
              <span class="font-mono text-xs tabular-nums text-fg-muted">{count}</span>
            </:col>
            <:action :let={{set, _count}} :if={@can_manage?}>
              <button
                id={"group-set-#{set.id}-edit"}
                type="button"
                phx-click={
                  JS.push("edit_set", value: %{id: set.id}) |> show_overlay("group-set-panel")
                }
                class="min-h-tap cursor-pointer text-sm text-link hover:underline"
              >
                Edit
              </button>
              <button
                id={"group-set-#{set.id}-delete"}
                type="button"
                phx-click={show_overlay("delete-group-set-#{set.id}")}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Delete
              </button>
            </:action>
            <:empty>No group sets yet.</:empty>
          </.table>
        </.settings_section>

        <p :if={!@can_manage?} id="groups-read-only" class="text-sm text-fg-muted">
          Owners and admins define groups. You see the groups that hold a resource you can read.
        </p>
      </.settings_page>

      <.confirm_dialog
        :for={group <- @groups}
        :if={@can_manage?}
        id={"delete-group-#{group.id}"}
        title={"Delete #{group.name}?"}
        confirm_label="Delete group"
        on_confirm={JS.push("delete", value: %{id: group.id})}
      >
        <%= if group.member_count > 0 do %>
          {member_label(group.member_count)} will leave the group. Each change is recorded on the resource.
        <% else %>
          The group has no members.
        <% end %>
      </.confirm_dialog>

      <.confirm_dialog
        :for={{set, count} <- @sets}
        :if={@can_manage?}
        id={"delete-group-set-#{set.id}"}
        title={"Delete #{set.name}?"}
        confirm_label="Delete set"
        on_confirm={JS.push("delete_set", value: %{id: set.id})}
      >
        <%= if count > 0 do %>
          Its {count} {if count == 1, do: "group stays", else: "groups stay"}, outside any set, with their members.
        <% else %>
          The set has no groups.
        <% end %>
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage?}
        id="group-panel"
        title={if @editing, do: "Edit #{@editing.name}", else: "New group"}
      >
        <.form for={@form} id="group-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:name]} type="text" label="Name" required autocomplete="off" />
          <.input field={@form[:description]} type="textarea" label="Description" rows="3" />
          <.input
            field={@form[:group_set_id]}
            type="select"
            label="Set"
            prompt="No set"
            options={@set_options}
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("group-panel")}>Cancel</.button>
            <.button id="group-save" variant="primary" phx-disable-with="Saving…">Save group</.button>
          </div>
        </.form>

        <section :if={@editing} id="group-members" class="mt-6 border-t border-line pt-4">
          <h3 class="text-sm font-medium text-fg">Direct members</h3>
          <ul class="mt-2 divide-y divide-line">
            <li
              :for={resource <- @members}
              id={"group-member-#{resource.id}"}
              class="flex items-center gap-2 py-1.5"
            >
              <.link
                navigate={~p"/inventory/#{resource.id}"}
                class="min-w-0 flex-1 truncate text-sm text-link hover:underline"
              >
                {resource.display_name || resource.name}
              </.link>
              <button
                :if={@can_change_membership?}
                id={"group-member-#{resource.id}-remove"}
                type="button"
                phx-click={JS.push("remove_member", value: %{id: resource.id, group_id: @editing.id})}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Remove
              </button>
            </li>
            <li :if={@members == []} class="py-1.5 text-sm text-fg-muted">
              No resources yet. Add them from a resource's page.
            </li>
          </ul>
        </section>
      </.side_panel>

      <.side_panel
        :if={@can_manage?}
        id="group-set-panel"
        title={if @editing_set, do: "Edit #{@editing_set.name}", else: "New group set"}
      >
        <.form for={@set_form} id="group-set-form" phx-change="validate_set" phx-submit="save_set">
          <.input field={@set_form[:name]} type="text" label="Name" required autocomplete="off" />
          <.input field={@set_form[:description]} type="textarea" label="Description" rows="3" />
          <.input
            field={@set_form[:exclusive]}
            type="checkbox"
            label="Exclusive: a resource belongs to at most one of its groups"
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("group-set-panel")}>Cancel</.button>
            <.button id="group-set-save" variant="primary" phx-disable-with="Saving…">
              Save set
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp member_label(1), do: "1 resource"
  defp member_label(count), do: "#{count} resources"
end
