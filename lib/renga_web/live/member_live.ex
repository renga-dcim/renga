defmodule RengaWeb.MemberLive do
  @moduledoc """
  Settings → Members: everyone in the organization with their base role and
  whether they are active (RFD 17, "Administration"). Holders of
  `members.manage` invite people by email and revoke pending invitations,
  and change a member's role or disable and re-enable them in a side panel
  that asks why; the reason goes to Activity. Pickers offer only roles
  within the actor's grant ceiling, and members above it are read-only.
  Renga.Members re-checks all of it.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory.Changes
  alias Renga.Members

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
       editing: nil,
       form: nil,
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
        |> respond(socket, "#{member.user.email} disabled")

      "enable" ->
        scope
        |> Members.enable_member(member.id, opts)
        |> respond(socket, "#{member.user.email} re-enabled")

      _role ->
        scope
        |> Members.change_role(member.id, params["role"], opts)
        |> respond(socket, "#{member.user.email} is now #{params["role"]}")
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
    do: "The organization needs at least one active owner. Make someone else an owner first."

  defp refusal(:self), do: "You can't disable yourself."

  defp refusal(:forbidden),
    do: "That change needs members.manage and a role that may grant both roles involved."

  defp refusal(_reason), do: "That member is no longer in this organization."

  defp load_members(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      members: Members.list_members(scope),
      invitations: if(socket.assigns.can_manage?, do: Members.list_invitations(scope), else: [])
    )
  end

  defp expired?(invitation), do: DateTime.before?(invitation.expires_at, DateTime.utc_now())

  defp manageable?(member, grantable), do: member.role in grantable

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
            <span class="block truncate font-medium text-fg">{member.user.email}</span>
            <span
              :if={member.id == @current_scope.membership_id}
              class="block text-xs text-fg-muted"
            >
              You
            </span>
          </:col>
          <:col :let={member} label="Role" class="w-28">
            <span class="capitalize text-fg">{member.role}</span>
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
              :if={manageable?(member, @grantable)}
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
                Invited by {invitation.invited_by_user.email}
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
        id="member-panel"
        title={if @editing, do: @editing.user.email, else: "Member"}
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
