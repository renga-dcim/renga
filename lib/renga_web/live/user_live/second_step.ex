defmodule RengaWeb.UserLive.SecondStep do
  @moduledoc """
  The second step of signing in for an account with MFA (RFD 19): a code
  from the authenticator app, or a recovery code when the app is lost. The
  form posts to `UserSessionController.second_step/2`, which checks the code
  and creates the session.
  """

  use RengaWeb, :live_view

  alias RengaWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card id="second_step" title="Confirm it's you">
        <:subtitle>
          Enter the code from your authenticator app for <span class="font-medium text-fg">{@email}</span>.
        </:subtitle>

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
        {:ok, assign(socket, email: user.email, form: to_form(%{}, as: "second_step"))}
    end
  end
end
