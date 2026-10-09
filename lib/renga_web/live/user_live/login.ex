defmodule RengaWeb.UserLive.Login do
  use RengaWeb, :live_view

  alias Renga.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card id="login" title="Log in">
        <:subtitle :if={@current_scope}>
          You need to reauthenticate to perform sensitive actions on your account.
        </:subtitle>
        <:subtitle :if={!@current_scope}>
          We'll email you a link, or you can use your password.
        </:subtitle>

        <div
          :if={local_mail_adapter?()}
          class="flex gap-2.5 rounded-md bg-info-fill px-3 py-2 text-sm text-fg"
        >
          <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-info" />
          <p>
            Emails go to the local mailbox in development: <.link
              href="/dev/mailbox"
              class="text-link underline"
            >open the mailbox</.link>.
          </p>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" class="w-full">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <.divider label="or use your password" />

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            spellcheck="false"
          />
          <div class="space-y-2">
            <.button
              variant="primary"
              class="w-full"
              name={@form[:remember_me].name}
              value="true"
            >
              Log in and stay logged in <span aria-hidden="true">→</span>
            </.button>
            <.button class="w-full">Log in only this time</.button>
          </div>
        </.form>

        <:footer :if={!@current_scope}>
          Don't have an account?
          <.link
            navigate={~p"/users/register"}
            class="font-medium text-link hover:underline"
          >
            Sign up
          </.link>
        </:footer>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:renga, Renga.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
