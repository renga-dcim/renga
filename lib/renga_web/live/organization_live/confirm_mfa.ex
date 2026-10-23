defmodule RengaWeb.OrganizationLive.ConfirmMFA do
  @moduledoc """
  Asks for a second factor, in place, before opening an organization that
  requires MFA (RFD 19). A member whose sign-in did not use one, such as
  a password alone or a provider not marked as enforcing MFA, confirms
  their passkey or authenticator code here without signing out; one with
  neither is sent to add one first. The form posts to
  `OrganizationSessionController.confirm_mfa/2`.
  """

  use RengaWeb, :live_view

  alias Renga.Accounts
  alias Renga.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card id="confirm_mfa" title="Confirm it's you">
        <:subtitle>
          <span class="font-medium text-fg">{@organization.name}</span>
          requires multi-factor authentication.
          <span :if={@factors?}>Use a passkey or a code from your authenticator app to open it.</span>
        </:subtitle>

        <div :if={not @factors?} id="confirm_mfa_enroll" class="space-y-3 text-sm text-fg-muted">
          <p>
            Your account has no passkey or authenticator app yet. Add one, then come back to open
            the organization.
          </p>
          <.button navigate={~p"/users/settings"} variant="primary" class="w-full">
            Add a passkey or authenticator app
          </.button>
        </div>

        <form
          :if={@passkey_options}
          id="confirm_mfa_passkey_form"
          action={~p"/organizations/confirm-mfa"}
          method="post"
          phx-hook="Passkey"
          phx-update="ignore"
          data-mode="get"
          data-options={Jason.encode!(@passkey_options)}
          class="space-y-2"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="confirm_mfa[passkey]" data-passkey-response />
          <.button type="button" variant="primary" class="w-full" data-passkey-start>
            <.icon name="hero-finger-print" class="size-4" /> Use a passkey
          </.button>
          <p data-passkey-status class="text-xs text-crit" role="status"></p>
        </form>

        <.divider :if={@passkey_options && @totp?} label="or enter a code" />

        <.form
          :if={@totp?}
          for={@form}
          id="confirm_mfa_form"
          action={~p"/organizations/confirm-mfa"}
        >
          <.input
            field={@form[:code]}
            type="text"
            label="Authenticator code"
            autocomplete="one-time-code"
            inputmode="numeric"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" class="w-full" phx-disable-with="Checking...">
            Continue <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <:footer>
          <.link navigate={~p"/organizations"} class="font-medium text-link hover:underline">
            Choose another organization
          </.link>
        </:footer>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_scope do
      %Scope{mfa_organization: %{} = organization, user: user} ->
        passkeys? = Accounts.list_passkeys(user) != []
        totp? = Accounts.MFA.totp_enabled?(user)

        passkey_options =
          if connected?(socket) and passkeys?,
            do: Accounts.passkey_options(user, "confirm_mfa")

        {:ok,
         assign(socket,
           page_title: "Confirm it's you",
           organization: organization,
           factors?: passkeys? or totp?,
           totp?: totp?,
           passkey_options: passkey_options,
           form: to_form(%{}, as: "confirm_mfa")
         )}

      %Scope{organization_id: organization_id} when is_binary(organization_id) ->
        {:ok, redirect(socket, to: ~p"/inbox")}

      _no_organization ->
        {:ok, redirect(socket, to: ~p"/organizations")}
    end
  end
end
