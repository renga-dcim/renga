defmodule RengaWeb.InvitationLive do
  @moduledoc """
  Accepting an invitation to an organization. The link carries the token;
  the signed-in account must have confirmed the invited address, which
  `Renga.Members.accept_invitation/2` checks again when the person accepts.
  Someone who is not signed in is sent to sign in or register first and
  returns here afterwards.
  """
  use RengaWeb, :live_view

  alias Renga.Members

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Invitation",
       token: token,
       invitation: Members.get_open_invitation(token)
     )}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    case Members.accept_invitation(socket.assigns.current_scope.user, socket.assigns.token) do
      {:ok, membership} ->
        {:noreply,
         socket
         |> put_flash(:info, "You joined #{membership.organization.name}. Open it below.")
         |> push_navigate(to: ~p"/organizations")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(reason))
         |> assign(:invitation, Members.get_open_invitation(socket.assigns.token))}
    end
  end

  defp refusal(:wrong_email),
    do:
      "This invitation is for a different email address. Sign in with that address, or confirm it first."

  defp refusal(:already_member), do: "You're already a member of this organization."

  defp refusal(:scoped_session),
    do:
      "You signed in with another organization's identity provider. Sign in another way to accept this invitation."

  defp refusal(:forbidden),
    do: "The person who invited you can no longer grant this role. Ask for a new invitation."

  defp refusal(_reason), do: "This invitation has expired, was revoked, or was already used."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:organizations}
    >
      <.settings_page
        id="invitation"
        title="Invitation"
        description="Joining an organization lets you work in its inventory with the role you were offered."
        class="max-w-xl"
      >
        <%= if @invitation do %>
          <div id="invitation-offer" class="rounded-lg border border-edge bg-surface p-4">
            <p class="text-sm text-fg">
              Join <span class="font-medium">{@invitation.organization.name}</span>
              as <span class="font-medium capitalize">{@invitation.role}</span>.
            </p>
            <p class="mt-1 text-xs text-fg-muted">
              For {@invitation.email} · expires {Calendar.strftime(
                @invitation.expires_at,
                "%Y-%m-%d"
              )}
            </p>
            <div class="mt-4 flex justify-end">
              <.button
                id="accept-invitation"
                variant="primary"
                phx-click="accept"
                phx-disable-with="Joining…"
              >
                Accept and join
              </.button>
            </div>
          </div>
        <% else %>
          <p id="invitation-invalid" class="text-sm text-fg-muted">
            This invitation has expired, was revoked, or was already used. Ask the person who invited you for a new one.
          </p>
        <% end %>
      </.settings_page>
    </Layouts.app>
    """
  end
end
