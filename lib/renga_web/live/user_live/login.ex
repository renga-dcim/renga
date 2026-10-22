defmodule RengaWeb.UserLive.Login do
  use RengaWeb, :live_view

  alias Renga.Accounts
  alias Renga.Accounts.SignInPolicy

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card id="login" title="Log in">
        <:subtitle :if={@local_sign_in}>
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

        <div :if={@organization} id="organization_provider_options" class="space-y-2">
          <p class="text-sm text-fg-muted">
            Log in to <span class="font-medium text-fg">{@organization.name}</span>
            with its identity provider.
          </p>
          <.button
            :for={provider <- @organization_providers}
            id={"provider-#{provider.id}"}
            href={~p"/users/log-in/provider/#{provider.id}"}
            variant="primary"
            class="w-full"
          >
            Log in with {provider.display_name}
          </.button>
        </div>

        <.divider
          :if={@organization != nil and (@providers != [] or @local_sign_in)}
          label="or another way"
        />

        <div :if={@providers != []} id="provider_options" class="space-y-2">
          <.button
            :for={provider <- @providers}
            id={"provider-#{provider.id}"}
            href={~p"/users/log-in/provider/#{provider.id}"}
            class="w-full"
          >
            Log in with {provider.display_name}
          </.button>
        </div>

        <.divider :if={@providers != [] and @local_sign_in} label="or" />

        <p :if={not @local_sign_in and @providers == []} class="text-sm text-fg-muted">
          No sign-in option is available right now.
        </p>

        <form
          :if={@local_sign_in and @passkey_options}
          id="passkey_login_form"
          action={~p"/users/log-in/passkey"}
          method="post"
          phx-hook="Passkey"
          phx-update="ignore"
          data-mode="get"
          data-conditional
          data-options={Jason.encode!(@passkey_options)}
          class="space-y-2"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="passkey[response]" data-passkey-response />
          <.button type="button" variant="primary" class="w-full" data-passkey-start>
            <.icon name="hero-finger-print" class="size-4" /> Log in with a passkey
          </.button>
          <p data-passkey-status class="text-xs text-crit" role="status"></p>
        </form>

        <.divider :if={@local_sign_in and @passkey_options} label="or use your email" />

        <.form
          :let={f}
          :if={@local_sign_in}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username webauthn"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" class="w-full">
            Log in with email <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <.divider :if={@local_sign_in} label="or use your password" />

        <.form
          :let={f}
          :if={@local_sign_in}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
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

        <:footer :if={@registration_open}>
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
  def mount(params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)

    form = to_form(%{"email" => email}, as: "user")

    # The challenge is single-use and stored, so only the connected render
    # asks for one.
    passkey_options = if connected?(socket), do: Accounts.passkey_sign_in_options()

    # An organization's sign-in link offers its own providers first. An
    # unknown organization, or one without any, shows the usual page.
    {organization, organization_providers} =
      Accounts.IdentityProviders.organization_sign_in_options(params["organization"]) ||
        {nil, []}

    {:ok,
     assign(socket,
       form: form,
       trigger_submit: false,
       passkey_options: passkey_options,
       organization: organization,
       organization_providers: organization_providers,
       providers: Accounts.IdentityProviders.sign_in_options(params["provider"]),
       local_sign_in: SignInPolicy.local_sign_in?(),
       registration_open: SignInPolicy.registration_open?()
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    user = if SignInPolicy.local_sign_in?(), do: Accounts.get_user_by_email(email)

    if user do
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
