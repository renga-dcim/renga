defmodule RengaWeb.MemberLive do
  @moduledoc """
  Settings → Members: everyone in the organization with their base role and
  whether they are active (RFD 17, "Administration"). Holders of
  `members.manage` invite people by email and revoke pending invitations,
  and change a member's role or disable and re-enable them in a side panel
  that asks why; the reason goes to Activity. Pickers offer only roles
  within the actor's grant ceiling, and members above it are read-only.
  Renga.Members re-checks all of it.

  With a SCIM connection (RFD 16), members it granted are marked and left
  to the identity provider, and its directory entries are listed, linked
  or not, so managers can tell who has not signed in yet.

  After an import (RFD 20), the people the archive named who were active
  members are listed until they are back, each with an invitation that
  restores their access when they accept it (`Renga.Transfers.Principals`).
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Accounts
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.User
  alias Renga.Assignments
  alias Renga.Inventory.Changes
  alias Renga.Members
  alias Renga.Roles.Assignment
  alias Renga.Scim
  alias Renga.Transfers.Principals

  @role_meanings %{
    "owner" => "Everything, including organization settings and export",
    "admin" => "Edits inventory and manages members, teams, and rules",
    "member" => "Reconciles, works findings, and proposes changes",
    "viewer" => "Reads inventory"
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: "Members",
       can_manage?: Members.can_manage?(scope),
       grantable: Members.grantable_roles(scope),
       assignable: Assignments.assignable_roles(scope),
       editing: nil,
       form: nil,
       assigning: nil,
       assign_form: nil,
       expiry_timer: nil,
       invite_form: to_form(Members.change_invitation(%{"role" => "member"}), as: :invitation)
     )
     |> load_members()}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil ->
        {:noreply, load_members(socket)}

      member ->
        form = to_form(%{"role" => member.role, "reason" => ""}, as: :member)
        {:noreply, assign(socket, editing: member, form: form)}
    end
  end

  # One form: its submit buttons say whether to change the role or the
  # status, so the reason travels with either.
  def handle_event("save", %{"member" => params} = form, socket) do
    %{current_scope: scope, editing: member} = socket.assigns
    opts = [reason: params["reason"]]

    case form["action"] do
      "disable" ->
        scope
        |> Members.disable_member(member.id, opts)
        |> respond(socket, "#{User.label(member.user)} disabled")

      "enable" ->
        scope
        |> Members.enable_member(member.id, opts)
        |> respond(socket, "#{User.label(member.user)} re-enabled")

      _role ->
        scope
        |> Members.change_role(member.id, params["role"], opts)
        |> respond(socket, "#{User.label(member.user)} is now #{params["role"]}")
    end
  end

  def handle_event("assignments", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.members, &(&1.id == id)) do
      nil -> {:noreply, load_members(socket)}
      member -> {:noreply, assign(socket, assigning: member, assign_form: assign_form())}
    end
  end

  def handle_event("assign", %{"assignment" => attrs}, socket) do
    %{current_scope: scope, assigning: member} = socket.assigns

    case Assignments.assign(scope, member.id, attrs) do
      {:ok, assignment} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{User.label(member.user)} now holds #{Assignment.role_name(assignment)}"
         )
         |> assign(:assign_form, assign_form())
         |> load_members()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :assign_form, to_form(changeset, as: :assignment, action: :insert))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load_members()}
    end
  end

  def handle_event("unassign", %{"id" => id}, socket) do
    case Assignments.unassign(socket.assigns.current_scope, id) do
      {:ok, assignment} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{Assignment.role_name(assignment)} taken away")
         |> load_members()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load_members()}
    end
  end

  def handle_event("invite", %{"invitation" => attrs}, socket) do
    scope = socket.assigns.current_scope

    case Members.invite(scope, attrs, &url(~p"/invitations/#{&1}")) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation sent to #{invitation.email}")
         |> close_overlay("invite-panel")
         |> assign(
           :invite_form,
           to_form(Members.change_invitation(%{"role" => "member"}), as: :invitation)
         )
         |> load_members()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :invite_form, to_form(changeset, as: :invitation, action: :insert))}

      {:error, {:delivery_failed, invitation}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Invitation saved, but the email could not be delivered. Try sending it again."
         )
         |> assign(
           :invite_form,
           to_form(
             Members.change_invitation(%{"email" => invitation.email, "role" => invitation.role}),
             as: :invitation
           )
         )
         |> load_members()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}
    end
  end

  def handle_event("invite_imported", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Principals.invite(scope, id, &url(~p"/invitations/#{&1}")) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation sent to #{invitation.email}")
         |> load_members()}

      {:error, {:delivery_failed, invitation}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Invitation for #{invitation.email} saved, but the email could not be delivered. Try sending it again."
         )
         |> load_members()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, imported_refusal(reason)) |> load_members()}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Members.revoke_invitation(socket.assigns.current_scope, id) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation for #{invitation.email} revoked")
         |> load_members()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> load_members()}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_members(socket)}

  def handle_info(:assignment_expiry, socket),
    do: {:noreply, socket |> assign(:expiry_timer, nil) |> load_members()}

  # Sending an invitation delivers mail from this process, and the test
  # mailer reports deliveries back to it.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp respond({:ok, _member}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> close_overlay("member-panel")
     |> assign(editing: nil, form: nil)
     |> load_members()}
  end

  defp respond({:error, reason}, socket, _message) do
    {:noreply, socket |> put_flash(:error, refusal(reason)) |> load_members()}
  end

  defp refusal(:last_owner),
    do:
      "The organization needs at least one active owner who isn't managed by SCIM. Make someone else an owner first."

  defp refusal(:self), do: "You can't disable yourself."

  defp refusal(:scim_managed),
    do: "Your identity provider manages this member through SCIM. Change their access there."

  defp refusal(:already_assigned), do: "They already hold that role."

  defp refusal(:forbidden),
    do: "That change needs members.manage and a role that may grant both roles involved."

  defp refusal(_reason), do: "That member is no longer in this organization."

  defp imported_refusal(%Ecto.Changeset{errors: [{:email, {message, _opts}} | _rest]}),
    do: "That address #{message}."

  defp imported_refusal(:not_eligible),
    do: "Only people who were active members can be invited back."

  defp imported_refusal(:not_found), do: "That person is already back."
  defp imported_refusal(reason), do: refusal(reason)

  defp load_members(socket) do
    previous = socket.assigns.current_scope
    scope = Accounts.scope_for_user(previous.user, previous.organization_id)

    if scope.organization_id == previous.organization_id do
      members = Members.list_members(scope)
      assignments = Assignments.list_assignments(scope) |> Enum.group_by(& &1.membership_id)
      can_manage? = Members.can_manage?(scope)
      invitations = if(can_manage?, do: Members.list_invitations(scope), else: [])

      socket
      |> assign(
        current_scope: scope,
        can_manage?: can_manage?,
        grantable: Members.grantable_roles(scope),
        assignable: Assignments.assignable_roles(scope),
        members: members,
        assignments: assignments,
        invitations: invitations,
        directory: Scim.list_directory_entries(scope),
        imported: if(can_manage?, do: returning(scope, members, invitations), else: []),
        editing: selected(socket.assigns.editing, members),
        assigning: selected(socket.assigns.assigning, members)
      )
      |> maybe_clear_management(can_manage?)
      |> schedule_expiry(scope)
    else
      push_navigate(socket, to: ~p"/organizations")
    end
  end

  # Imported people who can come back and are not members already, with
  # their open invitation if any.
  defp returning(scope, members, invitations) do
    invited = Map.new(invitations, &{&1.imported_principal_id, &1})
    member_emails = MapSet.new(members, &String.downcase(&1.user.email))

    for %{role: role} = entry when is_binary(role) <- Principals.list_unlinked(scope),
        not MapSet.member?(member_emails, String.downcase(entry.principal.email)),
        do: Map.put(entry, :invitation, invited[entry.principal.id])
  end

  defp selected(nil, _members), do: nil
  defp selected(member, members), do: Enum.find(members, &(&1.id == member.id))

  defp maybe_clear_management(socket, true), do: socket

  defp maybe_clear_management(socket, false),
    do: assign(socket, editing: nil, form: nil, assigning: nil, assign_form: nil)

  defp schedule_expiry(socket, scope) do
    if socket.assigns.expiry_timer, do: Process.cancel_timer(socket.assigns.expiry_timer)

    timer =
      if connected?(socket) do
        case Assignments.next_expiry(scope) do
          nil -> nil
          deadline -> Process.send_after(self(), :assignment_expiry, expiry_delay(deadline))
        end
      end

    assign(socket, :expiry_timer, timer)
  end

  defp expiry_delay(deadline) do
    deadline
    |> DateTime.diff(Renga.Time.utc_now_ms(), :millisecond)
    |> max(1)
    |> min(2_147_483_647)
  end

  defp assign_form,
    do: to_form(Assignments.change_assignment(), as: :assignment)

  defp role_options(%{built_in: built_in, custom: custom}) do
    [
      {"Built-in", for(role <- built_in, do: {String.capitalize(role), role})},
      {"Custom", for(role <- custom, do: {role.name, role.id})}
    ]
    |> Enum.reject(fn {_group, options} -> options == [] end)
  end

  defp removable?(%Assignment{built_in_role: nil, role_id: id}, assignable),
    do: Enum.any?(assignable.custom, &(&1.id == id))

  defp removable?(%Assignment{built_in_role: role}, assignable), do: role in assignable.built_in

  defp current?(assignment), do: Assignment.current?(assignment, DateTime.utc_now())

  defp expired?(invitation), do: DateTime.before?(invitation.expires_at, DateTime.utc_now())

  defp manageable?(member, grantable, assignments, assignable) do
    not OrganizationMembership.scim_managed?(member) and member.role in grantable and
      assignments
      |> Map.get(member.id, [])
      |> Enum.all?(&(not current?(&1) or removable?(&1, assignable)))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :role_meanings, @role_meanings)

    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:members}
    >
      <.settings_page
        id="members"
        title="Members"
        description="Everyone who can open this organization, and the role that decides what they may do."
      >
        <:actions>
          <.button
            :if={@can_manage?}
            id="invite-member"
            variant="primary"
            phx-click={show_overlay("invite-panel")}
          >
            Invite
          </.button>
        </:actions>
        <.table
          id="member-list"
          rows={@members}
          row_id={&"member-#{&1.id}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={member} label="Member" class="py-2">
            <span class="block truncate font-medium text-fg">{User.label(member.user)}</span>
            <span
              :if={member.id == @current_scope.membership_id}
              class="block text-xs text-fg-muted"
            >
              You
            </span>
            <span
              :if={OrganizationMembership.scim_managed?(member)}
              id={"member-#{member.id}-scim"}
              class="block text-xs text-fg-muted"
            >
              Managed by SCIM
            </span>
          </:col>
          <:col :let={member} label="Role" class="w-48">
            <span class="capitalize text-fg">{member.role}</span>
            <span
              :for={assignment <- Map.get(@assignments, member.id, [])}
              id={"member-#{member.id}-assignment-#{assignment.id}"}
              class={[
                "block truncate text-xs",
                if(current?(assignment), do: "text-fg-muted", else: "text-fg-muted line-through")
              ]}
            >
              + {Assignment.role_name(assignment)}
              <span :if={assignment.valid_until}>
                until {Calendar.strftime(assignment.valid_until, "%Y-%m-%d %H:%M")} UTC
              </span>
            </span>
          </:col>
          <:col :let={member} label="Status" class="w-28">
            <span
              id={"member-#{member.id}-status"}
              class={[
                "inline-flex items-center gap-1.5 text-xs font-medium",
                if(member.status == "active", do: "text-ok", else: "text-fg-muted")
              ]}
            >
              <span class={[
                "size-1.5 rounded-full",
                if(member.status == "active", do: "bg-ok", else: "bg-unknown")
              ]} />
              {String.capitalize(member.status)}
            </span>
          </:col>
          <:action :let={member} :if={@can_manage?}>
            <button
              id={"member-#{member.id}-roles"}
              type="button"
              phx-click={
                JS.push("assignments", value: %{id: member.id}) |> show_overlay("assign-panel")
              }
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Roles
            </button>
            <button
              :if={manageable?(member, @grantable, @assignments, @assignable)}
              id={"member-#{member.id}-edit"}
              type="button"
              phx-click={JS.push("edit", value: %{id: member.id}) |> show_overlay("member-panel")}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Manage
            </button>
          </:action>
        </.table>

        <section :if={@invitations != []} id="invitations" class="space-y-2">
          <h2 class="text-sm font-medium text-fg">Pending invitations</h2>
          <.table
            id="invitation-list"
            rows={@invitations}
            row_id={&"invitation-#{&1.id}"}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={invitation} label="Email" class="py-2">
              <span class="block truncate text-fg">{invitation.email}</span>
              <span :if={invitation.invited_by_user} class="block truncate text-xs text-fg-muted">
                Invited by {User.label(invitation.invited_by_user)}
              </span>
              <span
                :if={invitation.invited_by_operator}
                class="block truncate text-xs text-fg-muted"
              >
                Invited by the deployment ({invitation.invited_by_operator})
              </span>
            </:col>
            <:col :let={invitation} label="Role" class="w-28">
              <span class="capitalize text-fg">{invitation.role}</span>
            </:col>
            <:col :let={invitation} label="Expires" class="w-36 text-fg-muted">
              <%= if expired?(invitation) do %>
                Expired
              <% else %>
                {Calendar.strftime(invitation.expires_at, "%Y-%m-%d")}
              <% end %>
            </:col>
            <:action :let={invitation}>
              <button
                :if={invitation.role in @grantable}
                id={"invitation-#{invitation.id}-revoke"}
                type="button"
                phx-click={JS.push("revoke", value: %{id: invitation.id})}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
              >
                Revoke
              </button>
            </:action>
          </.table>
        </section>

        <section :if={@directory != []} id="directory" class="space-y-2">
          <div>
            <h2 class="text-sm font-medium text-fg">Directory</h2>
            <p class="mt-1 text-xs text-fg-muted">
              Everyone your identity provider assigned through SCIM. An entry gives access once its person signs in with the provider.
            </p>
          </div>
          <.table
            id="directory-list"
            rows={@directory}
            row_id={fn {entry, _user} -> "directory-#{entry.id}" end}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={{entry, _user}} label="Entry" class="py-2">
              <span class="block truncate font-medium text-fg">{entry.user_name}</span>
              <span
                :if={entry.display_name || entry.email}
                class="block truncate text-xs text-fg-muted"
              >
                {entry.display_name || entry.email}
              </span>
            </:col>
            <:col :let={{entry, user}} label="Account" class="w-56">
              <span
                :if={user}
                id={"directory-#{entry.id}-account"}
                class="block truncate text-fg"
              >
                {User.label(user)}
              </span>
              <span
                :if={!user}
                id={"directory-#{entry.id}-unlinked"}
                class="text-xs text-fg-muted"
              >
                Not signed in yet
              </span>
            </:col>
            <:col :let={{entry, _user}} label="Status" class="w-28">
              <span
                id={"directory-#{entry.id}-status"}
                class={[
                  "inline-flex items-center gap-1.5 text-xs font-medium",
                  if(entry.active, do: "text-ok", else: "text-fg-muted")
                ]}
              >
                <span class={[
                  "size-1.5 rounded-full",
                  if(entry.active, do: "bg-ok", else: "bg-unknown")
                ]} />
                {if entry.active, do: "Active", else: "Inactive"}
              </span>
            </:col>
          </.table>
        </section>

        <section :if={@imported != []} id="imported-people" class="space-y-2">
          <h2 class="text-sm font-medium text-fg">Imported people</h2>
          <p class="text-sm text-fg-muted">
            Active members of the organization this one was imported from. Accepting an invitation restores their teams, roles, and private views.
          </p>
          <.table
            id="imported-list"
            rows={@imported}
            row_id={&"imported-#{&1.principal.id}"}
            class="rounded-lg border border-edge bg-surface"
          >
            <:col :let={entry} label="Email" class="py-2">
              <span class="block truncate text-fg">{entry.principal.email}</span>
            </:col>
            <:col :let={entry} label="Role" class="w-28">
              <span class="capitalize text-fg">{entry.role}</span>
            </:col>
            <:col :let={entry} label="Invitation" class="w-36 text-fg-muted">
              <%= cond do %>
                <% is_nil(entry.invitation) -> %>
                  Not sent
                <% expired?(entry.invitation) -> %>
                  Expired
                <% true -> %>
                  Sent
              <% end %>
            </:col>
            <:action :let={entry}>
              <button
                :if={entry.role in @grantable}
                id={"imported-#{entry.principal.id}-invite"}
                type="button"
                phx-click={JS.push("invite_imported", value: %{id: entry.principal.id})}
                class="min-h-tap cursor-pointer whitespace-nowrap text-sm text-link hover:underline"
              >
                {if entry.invitation, do: "Send again", else: "Invite back"}
              </button>
            </:action>
          </.table>
        </section>

        <p :if={!@can_manage?} id="members-read-only" class="text-sm text-fg-muted">
          Owners and admins manage members.
        </p>
      </.settings_page>

      <.side_panel
        :if={@can_manage?}
        id="invite-panel"
        title="Invite a member"
        description="They get an emailed link that works for 7 days, only for an account with this address."
      >
        <.form for={@invite_form} id="invite-form" phx-submit="invite">
          <.input field={@invite_form[:email]} type="email" label="Email" required autocomplete="off" />
          <.input
            field={@invite_form[:role]}
            type="select"
            label="Role"
            options={for role <- @grantable, do: {String.capitalize(role), role}}
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("invite-panel")}>Cancel</.button>
            <.button id="invite-send" variant="primary" phx-disable-with="Sending…">
              Send invitation
            </.button>
          </div>
        </.form>
      </.side_panel>

      <.side_panel
        :if={@can_manage?}
        id="assign-panel"
        title={if @assigning, do: "Roles for #{User.label(@assigning.user)}", else: "Roles"}
        description="Further roles add to the base role. Access changes at once and is recorded in Activity."
      >
        <div :if={@assigning} id="assign-current" class="mb-4 space-y-1">
          <p class="text-sm text-fg">
            Base role: <span class="font-medium capitalize">{@assigning.role}</span>
          </p>
          <p
            :if={Map.get(@assignments, @assigning.id, []) == []}
            class="text-sm text-fg-muted"
          >
            No further roles.
          </p>
          <div
            :for={assignment <- Map.get(@assignments, @assigning.id, [])}
            id={"assignment-#{assignment.id}"}
            class="flex min-h-tap items-center justify-between gap-2 border-t border-edge py-1"
          >
            <span class="min-w-0 text-sm">
              <span class="block truncate font-medium text-fg">
                {Assignment.role_name(assignment)}
              </span>
              <span class="block truncate text-xs text-fg-muted">
                <%= cond do %>
                  <% !current?(assignment) -> %>
                    Expired
                  <% assignment.valid_until -> %>
                    Until {Calendar.strftime(assignment.valid_until, "%Y-%m-%d %H:%M")} UTC
                  <% true -> %>
                    No end date
                <% end %>
                <span :if={assignment.reason}>· {assignment.reason}</span>
              </span>
            </span>
            <button
              :if={removable?(assignment, @assignable)}
              id={"assignment-#{assignment.id}-remove"}
              type="button"
              phx-click={JS.push("unassign", value: %{id: assignment.id})}
              class="min-h-tap shrink-0 cursor-pointer text-sm text-crit hover:underline"
            >
              Remove
            </button>
          </div>
        </div>
        <.form :if={@assign_form} for={@assign_form} id="assign-form" phx-submit="assign">
          <.input
            field={@assign_form[:built_in_role]}
            name="assignment[role]"
            type="select"
            label="Give role"
            prompt="Choose a role"
            options={role_options(@assignable)}
          />
          <.input
            field={@assign_form[:valid_until]}
            type="datetime-local"
            label="Until (UTC, optional)"
          />
          <.input
            field={@assign_form[:reason]}
            type="textarea"
            label="Reason (optional)"
            rows="2"
            placeholder="Shown in Activity"
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("assign-panel")}>Close</.button>
            <.button id="assign-save" variant="primary" phx-disable-with="Saving…">
              Give role
            </.button>
          </div>
        </.form>
      </.side_panel>

      <.side_panel
        :if={@can_manage?}
        id="member-panel"
        title={if @editing, do: User.label(@editing.user), else: "Member"}
        description="Changes take effect at once and are recorded in Activity."
      >
        <.form :if={@form} for={@form} id="member-form" phx-submit="save">
          <.input
            field={@form[:role]}
            type="select"
            label="Role"
            options={for role <- @grantable, do: {String.capitalize(role), role}}
          />
          <dl class="mb-4 space-y-1 text-xs text-fg-muted">
            <div :for={role <- @grantable}>
              <dt class="inline font-medium capitalize text-fg">{role}</dt>
              <dd class="inline">· {@role_meanings[role]}</dd>
            </div>
          </dl>
          <.input
            field={@form[:reason]}
            type="textarea"
            label="Reason (optional)"
            rows="2"
            placeholder="Shown in Activity"
          />
          <div class="mt-4 flex flex-wrap items-center justify-between gap-2">
            <%= if @editing.status == "active" do %>
              <.button
                :if={@editing.id != @current_scope.membership_id}
                id="member-disable"
                name="action"
                value="disable"
                variant="ghost"
                class="text-crit"
              >
                Disable member
              </.button>
            <% else %>
              <.button id="member-enable" name="action" value="enable">
                Re-enable
              </.button>
            <% end %>
            <span class="flex-1" />
            <.button type="button" phx-click={hide_overlay("member-panel")}>Cancel</.button>
            <.button
              id="member-save"
              name="action"
              value="role"
              variant="primary"
              phx-disable-with="Saving…"
            >
              Save role
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end
end
