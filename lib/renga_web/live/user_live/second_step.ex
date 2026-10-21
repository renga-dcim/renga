defmodule RengaWeb.UserLive.SecondStep do
  @moduledoc """
  The second step of signing in for an account with MFA (RFD 19): a
  passkey, a code from the authenticator app, or a recovery code when both
  are lost. The
  form posts to `UserSessionController.second_step/2`, which checks the code
  and creates the session.
  """

  use RengaWeb, :live_view

  alias Renga.Accounts
  alias RengaWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card id="second_step" title="Confirm it's you">
        <:subtitle>
          Use a passkey or a code from your authenticator app for <span class="font-medium text-fg">{@email}</span>.
        </:subtitle>

        <form
          :if={@passkey_options}
          id="second_step_passkey_form"
          action={~p"/users/log-in/second-step"}
          method="post"
          phx-hook="Passkey"
          phx-update="ignore"
          data-mode="get"
          data-options={Jason.encode!(@passkey_options)}
          class="space-y-2"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="second_step[passkey]" data-passkey-response />
          <.button type="button" variant="primary" class="w-full" data-passkey-start>
            <.icon name="hero-finger-print" class="size-4" /> Use a passkey
          </.button>
          <p data-passkey-status class="text-xs text-crit" role="status"></p>
        </form>

        <.divider :if={@passkey_options} label="or enter a code" />

        <.form for={@form} id="second_step_form" action={~p"/users/log-in/second-step"}>
          <.input
            field={@form[:code]}
            type="text"
            label="Code"
            autocomplete="one-time-code"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" class="w-full" phx-disable-with="Checking...">
            Continue <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <p class="text-xs text-fg-muted">
          Lost your authenticator app? Enter one of your recovery codes instead.
        </p>

        <:footer>
          <.link navigate={~p"/users/log-in"} class="font-medium text-link hover:underline">
            Start over
          </.link>
        </:footer>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    case UserAuth.pending_second_step_user(session) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That sign-in expired. Sign in again.")
         |> redirect(to: ~p"/users/log-in")}

      user ->
        passkey_options =
          if connected?(socket) and Accounts.list_passkeys(user) != [],
            do: Accounts.passkey_options(user, "second_step")

        {:ok,
         assign(socket,
           email: user.email,
           form: to_form(%{}, as: "second_step"),
           passkey_options: passkey_options
         )}
    end
  end
end
