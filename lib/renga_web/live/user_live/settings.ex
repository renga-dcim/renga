defmodule RengaWeb.UserLive.Settings do
  @moduledoc """
  Account settings. The page opens without signing in again; saving a change
  that could take over the account asks for the account re-check in place
  (RFD 19), and the change goes through once it passes.
  """

  use RengaWeb, :live_view

  alias Renga.Accounts
  alias Renga.Accounts.MFA

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:account}
    >
      <.settings_page
        id="account"
        title="Account"
        description="How you sign in: your email, an optional password, and a second factor."
        class="max-w-3xl"
      >
        <div
          :if={@current_scope.user.session_organization_id}
          id="scoped_session_notice"
          class="flex gap-2.5 rounded-md bg-info-fill px-3 py-2 text-sm text-fg"
        >
          <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-info" />
          <p :if={@current_email && @first_credential_open}>
            Your login email is set. Add a password or passkey now to sign in to Renga another
            way; this works only for the next few minutes.
          </p>
          <p :if={@current_email && !@first_credential_open}>
            You signed in with your organization's identity provider, so this session can't
            change how you sign in. Sign in another way to change these settings.
          </p>
          <p :if={!@current_email}>
            Your organization's identity provider created this account, so it opens only that
            organization. To sign in to Renga another way, set up a login email, then add a
            password or passkey.
          </p>
        </div>
        <div
          :if={@recovering}
          id="recovery_notice"
          class="flex gap-2.5 rounded-md bg-info-fill px-3 py-2 text-sm text-fg"
        >
          <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-info" />
          <p>
            You signed in with a recovery code. Add a new passkey or replace your authenticator
            app now; this works only for the next few minutes.
          </p>
        </div>
        <.settings_section
          :if={!@current_email}
          id="account-email-initialization"
          title="Login email"
          description="Choose the address you'll sign in with. We email it a code to confirm it; your organization's identity provider can't confirm it for you."
        >
          <.form
            :if={!@email_initialization}
            for={@email_initialization_form}
            id="email_initialization_form"
            phx-submit="send_email_initialization"
          >
            <.input
              field={@email_initialization_form[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              spellcheck="false"
              required
            />
            <.button variant="primary" phx-disable-with="Sending...">Send code</.button>
          </.form>
          <.form
            :if={@email_initialization}
            for={@email_initialization.form}
            id="email_initialization_code_form"
            phx-submit="verify_email_initialization"
            class="space-y-3"
          >
            <p class="text-sm text-fg-muted">
              We emailed a code to <span class="font-medium text-fg">{@email_initialization.email}</span>. It works
              for {Accounts.Recheck.window_minutes()} minutes, in this browser only.
            </p>
            <.input
              field={@email_initialization.form[:code]}
              type="text"
              label="Code"
              autocomplete="one-time-code"
              spellcheck="false"
              required
            />
            <div class="flex flex-wrap gap-2">
              <.button variant="primary" phx-disable-with="Checking...">Confirm email</.button>
              <.button
                id="email_initialization_resend"
                type="button"
                phx-click="send_email_initialization"
                phx-value-email={@email_initialization.email}
              >
                Send a new code
              </.button>
              <.button
                id="email_initialization_restart"
                type="button"
                phx-click="restart_email_initialization"
              >
                Use another address
              </.button>
            </div>
          </.form>
        </.settings_section>

        <.settings_section
          :if={@current_email}
          id="account-email"
          title="Email"
          description="We send a link to the new address to confirm it before it changes."
        >
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
          </.form>
          <.recheck_panel :if={@recheck && @recheck.action == :change_email} recheck={@recheck} />
        </.settings_section>

        <.settings_section
          id="account-password"
          title="Password"
          description="Optional. With a passkey you can sign in without one."
        >
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              spellcheck="false"
            />
            <div class="flex flex-wrap gap-2">
              <.button variant="primary" phx-disable-with="Saving...">
                Save Password
              </.button>
              <.button
                :if={@has_password and @passkeys != []}
                id="password_remove"
                type="button"
                variant="danger"
                phx-click="remove_password"
              >
                Remove password
              </.button>
            </div>
          </.form>
          <.recheck_panel
            :if={@recheck && @recheck.action in [:set_password, :remove_password]}
            recheck={@recheck}
          />
        </.settings_section>

        <.settings_section
          id="account-passkeys"
          title="Passkeys"
          description="Sign in with your device's fingerprint, face, or PIN instead of a password. A passkey counts as a second factor by itself."
        >
          <ul :if={@passkeys != []} id="passkeys" class="mb-4 divide-y divide-line">
            <li
              :for={passkey <- @passkeys}
              id={"passkey-#{passkey.id}"}
              class="flex items-center justify-between gap-3 py-2"
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-medium text-fg">{passkey.name}</p>
                <p class="text-xs text-fg-muted">
                  Added {Calendar.strftime(passkey.inserted_at, "%b %-d, %Y")} · {last_used(passkey)}
                </p>
              </div>
              <.button
                size="sm"
                phx-click="remove_passkey"
                phx-value-id={passkey.id}
                aria-label={"Remove #{passkey.name}"}
              >
                Remove
              </.button>
            </li>
          </ul>

          <div
            id="passkey_register"
            phx-hook="Passkey"
            data-mode="create"
            data-reply="register_passkey"
          >
            <.form for={@passkey_form} id="passkey_form" phx-submit="add_passkey">
              <%!-- The form's value never changes, so LiveView would leave the
                   last name typed in the field; a new ID replaces the input
                   after each added passkey. --%>
              <.input
                field={@passkey_form[:name]}
                id={"passkey_name_#{length(@passkeys)}"}
                type="text"
                label="Name"
                spellcheck="false"
              />
              <.button id="passkey_add" variant="primary" phx-disable-with="Waiting...">
                Add a passkey
              </.button>
            </.form>
          </div>

          <.recheck_panel
            :if={@recheck && @recheck.action in [:add_passkey, :remove_passkey]}
            recheck={@recheck}
          />
        </.settings_section>

        <.settings_section
          id="account-mfa"
          title="Authenticator app"
          description="A six-digit code from an app such as 1Password or Google Authenticator, asked for after your password or emailed link."
        >
          <div :if={!@totp_enabled and !@totp_setup} class="space-y-3">
            <p :if={@totp_available} class="text-sm text-fg-muted">Off.</p>
            <p :if={!@totp_available} id="totp_unavailable" class="text-sm text-fg-muted">
              Off. This server has no encryption key for authenticator secrets yet.
            </p>
            <.button
              :if={@totp_available}
              id="totp_setup"
              variant="primary"
              phx-click="start_totp"
            >
              Set up authenticator app
            </.button>
          </div>

          <div :if={@totp_setup} id="totp_setup_panel" class="space-y-4">
            <p class="text-sm text-fg">
              Scan this code with your authenticator app, or enter the key by hand.
            </p>
            <div class="flex flex-wrap items-center gap-4">
              <div class="rounded-md bg-white p-2" aria-hidden="true">
                {Phoenix.HTML.raw(@totp_setup.qr_svg)}
              </div>
              <div class="min-w-0 space-y-1">
                <p class="text-xs text-fg-muted">Key</p>
                <p id="totp_secret" class="font-mono text-sm break-all text-fg">
                  {@totp_setup.formatted_secret}
                </p>
              </div>
            </div>
            <.form for={@totp_setup.form} id="totp_form" phx-submit="enable_totp">
              <.input
                field={@totp_setup.form[:code]}
                type="text"
                label="Code from the app"
                inputmode="numeric"
                autocomplete="one-time-code"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <div class="flex gap-2">
                <.button variant="primary" phx-disable-with="Checking...">Turn on</.button>
                <.button type="button" phx-click="cancel_totp">Cancel</.button>
              </div>
            </.form>
          </div>

          <div :if={@totp_enabled and !@totp_setup} class="space-y-3">
            <p id="totp_status" class="text-sm text-fg">On.</p>
            <div class="flex flex-wrap gap-2">
              <.button :if={@recovering} id="totp_replace" variant="primary" phx-click="start_totp">
                Replace authenticator app
              </.button>
              <.button id="totp_remove" variant="danger" phx-click="remove_totp">
                Remove
              </.button>
            </div>
          </div>

          <.recheck_panel
            :if={@recheck && @recheck.action in [:add_totp, :remove_totp]}
            recheck={@recheck}
          />
        </.settings_section>

        <.settings_section
          :if={@mfa or @new_recovery_codes}
          id="account-recovery"
          title="Recovery codes"
          description="Each code signs you in once if you lose your passkeys and authenticator app."
        >
          <div :if={!@new_recovery_codes} class="space-y-3">
            <p id="recovery_status" class="text-sm text-fg">
              {recovery_codes_text(@recovery_codes_left)}
            </p>
            <.button id="recovery_regenerate" phx-click="regenerate_recovery_codes">
              Generate new recovery codes
            </.button>
          </div>

          <div
            :if={@new_recovery_codes}
            id="recovery_codes"
            class="space-y-3 rounded-lg border border-edge bg-sunken p-4"
          >
            <p class="text-xs text-fg-muted">
              Save these somewhere safe now. They won't be shown again, and generating a new
              set replaces them.
            </p>
            <ul class="grid grid-cols-2 gap-x-6 gap-y-1 font-mono text-sm text-fg">
              <li :for={code <- @new_recovery_codes}>{code}</li>
            </ul>
            <.button type="button" phx-click="dismiss_recovery_codes">I've saved them</.button>
          </div>

          <.recheck_panel :if={@recheck && @recheck.action == :recovery_codes} recheck={@recheck} />
        </.settings_section>
        <.settings_section
          :if={@identities != [] or @linkable_providers != []}
          id="account-identities"
          title="Identity providers"
          description="Sign in with an account you already have at an identity provider. Connecting or disconnecting one asks you to confirm it's you."
        >
          <ul :if={@identities != []} id="identities" class="mb-4 divide-y divide-line">
            <li
              :for={identity <- @identities}
              id={"identity-#{identity.id}"}
              class="flex items-center justify-between gap-3 py-2"
            >
              <div class="min-w-0">
                <p class="truncate text-sm font-medium text-fg">
                  {identity.provider.display_name}
                </p>
                <p class="truncate text-xs text-fg-muted">
                  {identity_detail(identity)}
                </p>
              </div>
              <.button
                size="sm"
                phx-click="unlink_identity"
                phx-value-id={identity.id}
                aria-label={"Disconnect #{identity.provider.display_name}"}
              >
                Disconnect
              </.button>
            </li>
          </ul>

          <div :if={@linkable_providers != []} id="linkable_providers" class="flex flex-wrap gap-2">
            <.button
              :for={provider <- @linkable_providers}
              id={"link-#{provider.id}"}
              type="button"
              phx-click="link_identity"
              phx-value-provider={provider.id}
            >
              Connect {provider.display_name}
            </.button>
          </div>

          <%!-- Linking leaves the page for the provider, so it is a real form
               post, submitted once the re-check passes. --%>
          <.form
            for={%{}}
            id="identity_link_form"
            action={~p"/users/settings/identities"}
            method="post"
            phx-trigger-action={not is_nil(@link_provider)}
          >
            <input type="hidden" name="provider" value={@link_provider} />
          </.form>

          <.recheck_panel
            :if={@recheck && @recheck.action in [:link_identity, :unlink_identity]}
            recheck={@recheck}
          />
        </.settings_section>
        <.settings_section
          id="account-security-log"
          title="Security log"
          description="Recent sign-ins and changes to how you sign in. We also email you about every change."
        >
          <p :if={@security_events == []} class="text-sm text-fg-muted">Nothing yet.</p>
          <ul :if={@security_events != []} id="security_events" class="divide-y divide-line">
            <li
              :for={event <- @security_events}
              class="flex items-baseline justify-between gap-3 py-1.5 text-sm"
            >
              <span class="min-w-0 break-words text-fg">{Accounts.describe_security_event(event)}</span>
              <time
                datetime={DateTime.to_iso8601(event.inserted_at)}
                class="shrink-0 text-xs text-fg-muted tabular-nums"
              >
                {Calendar.strftime(event.inserted_at, "%b %-d, %H:%M UTC")}
              </time>
            </li>
          </ul>
        </.settings_section>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :recheck, :map, required: true

  # The in-place re-check, shown under the change that asked for it.
  defp recheck_panel(assigns) do
    ~H"""
    <div
      id="recheck"
      role="group"
      aria-labelledby="recheck-title"
      class="mt-4 space-y-3 rounded-lg border border-edge bg-sunken p-4"
    >
      <div>
        <h3 id="recheck-title" class="text-sm font-medium text-fg">Confirm it's you</h3>
        <p class="mt-1 text-xs text-fg-muted">
          {recheck_description(@recheck)}
        </p>
      </div>

      <div
        :if={:passkey in @recheck.methods}
        id="recheck_passkey"
        phx-hook="Passkey"
        data-mode="get"
        data-reply="recheck_passkey"
        class="flex gap-2"
      >
        <.button id="recheck_passkey_start" variant="primary" phx-click="start_recheck_passkey">
          <.icon name="hero-finger-print" class="size-4" /> Use a passkey
        </.button>
        <.button :if={:totp not in @recheck.methods} type="button" phx-click="cancel_recheck">
          Cancel
        </.button>
      </div>
      <p
        :for={{message, _opts} <- passkey_errors(@recheck)}
        id="recheck_passkey_error"
        role="alert"
        class="flex items-center gap-1.5 text-xs text-crit"
      >
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
        {message}
      </p>

      <.divider :if={:passkey in @recheck.methods and :totp in @recheck.methods} label="or" />

      <.form
        :if={:totp in @recheck.methods}
        for={@recheck.form}
        id="recheck_totp_form"
        phx-submit="recheck_totp"
      >
        <.input
          field={@recheck.form[:code]}
          type="text"
          label="Code from your authenticator app"
          inputmode="numeric"
          autocomplete="one-time-code"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <div class="flex gap-2">
          <.button variant="primary" phx-disable-with="Checking...">Confirm</.button>
          <.button type="button" phx-click="cancel_recheck">Cancel</.button>
        </div>
      </.form>

      <.form
        :if={:password in @recheck.methods}
        for={@recheck.form}
        id="recheck_form"
        phx-submit="recheck_password"
      >
        <.input
          field={@recheck.form[:password]}
          type="password"
          label="Current password"
          autocomplete="current-password"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <div class="flex gap-2">
          <.button variant="primary" phx-disable-with="Checking...">Confirm</.button>
          <.button type="button" phx-click="cancel_recheck">Cancel</.button>
        </div>
      </.form>

      <%!-- Signing in again leaves the page, so this is a real form post. --%>
      <.form
        :if={:provider in @recheck.methods}
        for={%{}}
        id="recheck_provider_form"
        action={~p"/users/settings/recheck"}
        method="post"
        class="flex flex-wrap gap-2"
      >
        <.button
          :for={identity <- @recheck.identities}
          id={"recheck_identity-#{identity.id}"}
          variant="primary"
          name="identity"
          value={identity.id}
        >
          Confirm with {identity.provider.display_name}
        </.button>
        <.button type="button" phx-click="cancel_recheck">Cancel</.button>
      </.form>

      <div :if={bootstrap?(@recheck) and not @recheck.code_sent} class="flex gap-2">
        <.button id="bootstrap_send" variant="primary" phx-click="send_bootstrap_code">
          Email me a code
        </.button>
        <.button type="button" phx-click="cancel_recheck">Cancel</.button>
      </div>

      <.form
        :if={bootstrap?(@recheck) and @recheck.code_sent}
        for={@recheck.form}
        id="bootstrap_form"
        phx-submit="verify_bootstrap_code"
      >
        <.input
          field={@recheck.form[:code]}
          type="text"
          label="Code from the email"
          autocomplete="one-time-code"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <div class="flex gap-2">
          <.button variant="primary" phx-disable-with="Checking...">Confirm</.button>
          <.button type="button" phx-click="send_bootstrap_code">Send a new code</.button>
          <.button type="button" phx-click="cancel_recheck">Cancel</.button>
        </div>
      </.form>

      <.button
        :if={@recheck.methods == [] and not bootstrap?(@recheck)}
        type="button"
        phx-click="cancel_recheck"
      >
        Close
      </.button>
    </div>
    """
  end

  # A scoped session that set up its login email may add the account's first
  # credential for a few minutes (RFD 15); the notice says so.
  defp assign_first_credential_open(socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    open? =
      !!(user.session_organization_id && user.email && session_token &&
           Accounts.authorized_account_change?(user, session_token, :set_password))

    assign(socket, :first_credential_open, open?)
  end

  defp bootstrap?(%{methods: [], change: change}), do: change in [:set_password, :add_factor]
  defp bootstrap?(_recheck), do: false

  defp recheck_description(%{methods: [:passkey | _]}),
    do:
      "Use a passkey or an authenticator code. It covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [:totp | _]}),
    do:
      "Enter a code from your authenticator app. It covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [:password | _]}),
    do:
      "Enter your current password. It covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [:provider]}),
    do:
      "Sign in again at your identity provider. You'll come back here, and it covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [], code_sent: true}),
    do: "Enter the code we emailed to your current address. It expires in five minutes."

  defp recheck_description(%{methods: []} = recheck) do
    cond do
      bootstrap?(recheck) ->
        "Your account has no password or authenticator app yet. We'll email a code to your current address to confirm the first one."

      recheck.change in [:link_identity, :unlink_identity] ->
        "Add a password or passkey first. Your account needs a way to confirm it's you before its sign-in options change."

      true ->
        "Set a password first. Your account needs a way to confirm it's you before its email changes."
    end
  end

  defp identity_detail(%{email: email, last_signed_in_at: at}) do
    used = if at, do: "last used " <> Calendar.strftime(at, "%b %-d, %Y"), else: "never used"
    if email, do: "#{email} · #{used}", else: used
  end

  defp last_used(%{last_used_at: nil}), do: "never used"

  defp last_used(%{last_used_at: at}),
    do: "last used " <> Calendar.strftime(at, "%b %-d, %Y")

  defp recovery_codes_text(1), do: "1 recovery code left."
  defp recovery_codes_text(count), do: "#{count} recovery codes left."

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, :scoped_session} ->
          put_flash(
            socket,
            :error,
            "This session signed in with your organization's identity provider. Sign in another way, then open the link again."
          )

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:session_token, session["user_token"])
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:recheck, nil)
      |> assign(:totp_setup, nil)
      |> assign(:new_recovery_codes, nil)
      |> assign(:pending_passkey_name, nil)
      |> assign(:passkey_form, passkey_form())
      |> assign(:link_provider, nil)
      |> assign(:email_initialization, nil)
      |> assign(:email_initialization_form, email_initialization_form(%{}))
      |> assign_mfa()
      |> assign_first_credential_open()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} ->
        {:noreply, with_recheck(socket, :change_email, user_params)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    # Keep the typed password in the form: the controller post that follows
    # the re-check submits it.
    case Accounts.change_user_password(user, user_params, hash_password: false) do
      %{valid?: true} = changeset ->
        socket
        |> assign(:password_form, to_form(changeset))
        |> with_recheck(:set_password, user_params)
        |> then(&{:noreply, &1})

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  def handle_event("recheck_password", %{"recheck" => %{"password" => password}}, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.recheck_with_password(user, session_token, password) do
      :ok ->
        {:noreply, resume(socket)}

      {:error, _reason} ->
        {:noreply, recheck_error(socket, :password, "That password isn't right.")}
    end
  end

  def handle_event("recheck_totp", %{"recheck" => %{"code" => code}}, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.recheck_with_totp(user, session_token, code) do
      :ok ->
        {:noreply, resume(socket)}

      {:error, :rate_limited} ->
        {:noreply, recheck_error(socket, :code, "Too many wrong codes. Try again later.")}

      {:error, _reason} ->
        {:noreply, recheck_error(socket, :code, "That code isn't right.")}
    end
  end

  def handle_event("start_totp", _params, socket) do
    if MFA.totp_available?(),
      do: {:noreply, with_recheck(socket, :add_totp, %{})},
      else: {:noreply, socket}
  end

  # A submission with no setup open, from a stale or crafted event, does
  # nothing.
  def handle_event("enable_totp", _params, %{assigns: %{totp_setup: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("enable_totp", %{"totp" => %{"code" => code}}, socket) do
    %{current_scope: %{user: user}, session_token: session_token, totp_setup: setup} =
      socket.assigns

    case Accounts.add_totp(user, session_token, setup.secret, code) do
      {:ok, codes} ->
        {:noreply,
         socket
         |> assign(:totp_setup, nil)
         |> assign(:new_recovery_codes, codes)
         |> assign_mfa()
         |> put_flash(:info, "Authenticator app turned on.")}

      {:error, :recheck_required} ->
        {:noreply, with_recheck(socket, :add_totp, %{})}

      {:error, :already_enabled} ->
        {:noreply, socket |> assign(:totp_setup, nil) |> assign_mfa()}

      {:error, :no_encryption_key} ->
        {:noreply,
         socket
         |> assign(:totp_setup, nil)
         |> put_flash(:error, "Authenticator apps aren't available on this server yet.")}

      {:error, :invalid_code} ->
        form =
          to_form(%{"code" => ""}, as: "totp", errors: [code: {"That code isn't right.", []}])

        {:noreply, update(socket, :totp_setup, &%{&1 | form: form})}
    end
  end

  def handle_event("cancel_totp", _params, socket) do
    {:noreply, assign(socket, :totp_setup, nil)}
  end

  def handle_event("remove_totp", _params, socket) do
    {:noreply, with_recheck(socket, :remove_totp, %{})}
  end

  def handle_event("add_passkey", %{"passkey" => %{"name" => name}}, socket) do
    name = if String.trim(name) == "", do: "Passkey", else: name
    {:noreply, with_recheck(socket, :add_passkey, %{"name" => name})}
  end

  def handle_event("register_passkey", %{"response" => response}, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns
    name = socket.assigns.pending_passkey_name || "Passkey"

    case Accounts.add_passkey(user, session_token, response, name) do
      {:ok, passkey, codes} ->
        {:noreply,
         socket
         |> assign(:pending_passkey_name, nil)
         |> assign(:passkey_form, passkey_form())
         |> assign(:new_recovery_codes, codes || socket.assigns.new_recovery_codes)
         |> assign_mfa()
         |> put_flash(:info, "Passkey “#{passkey.name}” added.")}

      {:error, :recheck_required} ->
        {:noreply, with_recheck(socket, :add_passkey, %{"name" => name})}

      {:error, :already_registered} ->
        {:noreply, put_flash(socket, :error, "That passkey is already on an account.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The passkey couldn't be added. Try again.")}
    end
  end

  def handle_event("register_passkey", %{"error" => _name}, socket) do
    {:noreply, put_flash(socket, :error, "The passkey wasn't added.")}
  end

  def handle_event("remove_password", _params, socket) do
    {:noreply, with_recheck(socket, :remove_password, %{})}
  end

  def handle_event("remove_passkey", %{"id" => id}, socket) do
    {:noreply, with_recheck(socket, :remove_passkey, %{"id" => id})}
  end

  def handle_event("start_recheck_passkey", _params, socket) do
    options = Accounts.passkey_options(socket.assigns.current_scope.user, "recheck")

    {:noreply,
     push_event(socket, "passkey:start", %{target: "recheck_passkey", options: options})}
  end

  def handle_event("recheck_passkey", %{"response" => response}, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.recheck_with_passkey(user, session_token, response) do
      :ok -> {:noreply, resume(socket)}
      {:error, _reason} -> {:noreply, recheck_error(socket, :code, "That passkey didn't work.")}
    end
  end

  def handle_event("recheck_passkey", %{"error" => _name}, socket) do
    {:noreply, recheck_error(socket, :code, "That passkey didn't work.")}
  end

  def handle_event("regenerate_recovery_codes", _params, socket) do
    {:noreply, with_recheck(socket, :recovery_codes, %{})}
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    {:noreply, assign(socket, :new_recovery_codes, nil)}
  end

  # The email bootstrap only stands in for a change it can authorize. Its
  # controls are hidden otherwise, and a crafted event does nothing.
  def handle_event("send_bootstrap_code", _params, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    with true <- bootstrap?(socket.assigns.recheck),
         {:ok, _email} <- Accounts.deliver_bootstrap_code(user, session_token) do
      {:noreply,
       socket
       |> update(:recheck, &%{&1 | code_sent: true, form: recheck_form()})
       |> put_flash(:info, "We emailed a code to #{user.email}.")}
    else
      false -> {:noreply, socket}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "The code could not be sent.")}
    end
  end

  def handle_event("verify_bootstrap_code", %{"recheck" => %{"code" => code}}, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    with true <- bootstrap?(socket.assigns.recheck),
         :ok <- Accounts.verify_bootstrap_code(user, session_token, code) do
      {:noreply, resume(socket)}
    else
      false ->
        {:noreply, socket}

      {:error, :invalid_code} ->
        {:noreply, recheck_error(socket, :code, "That code isn't right.")}

      {:error, _reason} ->
        {:noreply, recheck_error(socket, :code, "That code has expired. Send a new one.")}
    end
  end

  # Only an account with no email and no credential, such as one an
  # organization's provider created, gets this far (RFD 15); for anyone
  # else these events are refused.
  def handle_event("send_email_initialization", params, socket) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    email =
      String.trim(get_in(params, ["email_initialization", "email"]) || params["email"] || "")

    case Accounts.deliver_email_initialization_code(user, session_token, email) do
      {:ok, _sent} ->
        {:noreply,
         socket
         |> assign(:email_initialization, %{
           email: email,
           form: to_form(%{}, as: "email_initialization")
         })
         |> put_flash(:info, "We emailed a code to #{email}.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:email_initialization, nil)
         |> assign(
           :email_initialization_form,
           to_form(changeset, as: "email_initialization", action: :insert)
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The code could not be sent.")}
    end
  end

  def handle_event(
        "verify_email_initialization",
        _params,
        %{assigns: %{email_initialization: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event(
        "verify_email_initialization",
        %{"email_initialization" => %{"code" => code}},
        socket
      ) do
    %{current_scope: %{user: user} = scope, session_token: session_token} = socket.assigns

    case Accounts.verify_email_initialization_code(user, session_token, code) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | user: user})
         |> assign(:current_email, user.email)
         |> assign(
           :email_form,
           to_form(Accounts.change_user_email(user, %{}, validate_unique: false))
         )
         |> assign(:email_initialization, nil)
         |> assign_mfa()
         |> assign_first_credential_open()
         |> put_flash(
           :info,
           "#{user.email} is your login email. Add a password or passkey in the next #{Accounts.Recheck.window_minutes()} minutes."
         )}

      {:error, reason} ->
        {:noreply, email_initialization_error(socket, reason)}
    end
  end

  def handle_event("restart_email_initialization", _params, socket) do
    {:noreply,
     socket
     |> assign(:email_initialization, nil)
     |> assign(:email_initialization_form, email_initialization_form(%{}))}
  end

  def handle_event("link_identity", %{"provider" => id}, socket) do
    if Enum.any?(socket.assigns.linkable_providers, &(&1.id == id)),
      do: {:noreply, with_recheck(socket, :link_identity, %{"provider" => id})},
      else: {:noreply, socket}
  end

  def handle_event("unlink_identity", %{"id" => id}, socket) do
    {:noreply, with_recheck(socket, :unlink_identity, %{"id" => id})}
  end

  def handle_event("cancel_recheck", _params, socket) do
    {:noreply, assign(socket, :recheck, nil)}
  end

  # Runs `action` now if this session is already authorized for the change
  # it makes, otherwise asks for the re-check and keeps the action to resume
  # afterwards.
  defp with_recheck(socket, action, params) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns
    change = guarded_change(action)

    cond do
      Accounts.authorized_account_change?(user, session_token, change) ->
        apply_change(socket, action, params)

      # No re-check can authorize it (RFD 15), so none is offered. Only a
      # login email set up from this session lets it add a first credential.
      user.session_organization_id && is_nil(user.email) ->
        put_flash(socket, :error, "Set up your login email first.")

      user.session_organization_id ->
        put_flash(socket, :error, "Sign in another way to change how you sign in.")

      true ->
        assign(socket, :recheck, %{
          action: action,
          change: change,
          params: params,
          methods: Accounts.recheck_methods(user),
          identities: Accounts.recheck_identities(user),
          code_sent: false,
          form: recheck_form()
        })
    end
  end

  # A passed check only resumes the pending change through the same
  # authorization test that asked for it, so evidence that cannot authorize
  # that change, such as the email bootstrap for an email change, asks again.
  defp resume(%{assigns: %{recheck: %{action: action, params: params}}} = socket) do
    socket
    |> assign(:recheck, nil)
    |> with_recheck(action, params)
  end

  defp resume(socket), do: socket

  defp guarded_change(action) when action in [:add_totp, :add_passkey], do: :add_factor
  defp guarded_change(action) when action in [:remove_totp, :remove_passkey], do: :remove_factor
  defp guarded_change(:remove_password), do: :set_password
  defp guarded_change(action), do: action

  defp apply_change(socket, :change_email, user_params) do
    user = socket.assigns.current_scope.user
    changeset = Accounts.change_user_email(user, user_params)

    Accounts.deliver_user_update_email_instructions(
      Ecto.Changeset.apply_action!(changeset, :insert),
      user.email,
      &url(~p"/users/settings/confirm-email/#{&1}")
    )

    info = "A link to confirm your email change has been sent to the new address."
    put_flash(socket, :info, info)
  end

  # The password form posts to the session controller, which signs this
  # browser back in after every other session ends.
  defp apply_change(socket, :set_password, _user_params) do
    assign(socket, :trigger_submit, true)
  end

  defp apply_change(%{assigns: %{totp_setup: nil}} = socket, :add_totp, _params) do
    secret = MFA.new_totp_secret()
    uri = MFA.totp_uri(socket.assigns.current_scope.user, secret)

    assign(socket, :totp_setup, %{
      secret: secret,
      formatted_secret: MFA.format_totp_secret(secret),
      qr_svg: uri |> EQRCode.encode() |> EQRCode.svg(width: 176),
      form: to_form(%{}, as: "totp")
    })
  end

  defp apply_change(socket, :add_totp, _params), do: socket

  defp apply_change(socket, :add_passkey, %{"name" => name}) do
    options = Accounts.passkey_registration_options(socket.assigns.current_scope.user)

    socket
    |> assign(:pending_passkey_name, name)
    |> push_event("passkey:start", %{target: "passkey_register", options: options})
  end

  defp apply_change(socket, :remove_passkey, %{"id" => id}) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.remove_passkey(user, session_token, id) do
      {:ok, passkey} ->
        socket
        |> assign_mfa()
        |> put_flash(:info, "Passkey “#{passkey.name}” removed.")

      {:error, :last_passkey} ->
        put_flash(socket, :error, "Set a password before removing your last passkey.")

      {:error, _reason} ->
        put_flash(socket, :error, "The passkey could not be removed.")
    end
  end

  defp apply_change(socket, :remove_password, _params) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.remove_user_password(user, session_token) do
      {:ok, user} ->
        socket
        |> update(:current_scope, &%{&1 | user: user})
        |> assign_mfa()
        |> put_flash(:info, "Password removed. Sign in with your passkey from now on.")

      {:error, _reason} ->
        put_flash(socket, :error, "The password could not be removed.")
    end
  end

  defp apply_change(socket, :remove_totp, _params) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.remove_totp(user, session_token) do
      {:ok, _user} ->
        socket
        |> assign(:new_recovery_codes, nil)
        |> assign_mfa()
        |> put_flash(:info, "Authenticator app removed.")

      {:error, _reason} ->
        put_flash(socket, :error, "The authenticator app could not be removed.")
    end
  end

  # The form post starts the provider round trip; the controller checks the
  # re-check again before it binds the attempt to this session.
  defp apply_change(socket, :link_identity, %{"provider" => id}) do
    assign(socket, :link_provider, id)
  end

  defp apply_change(socket, :unlink_identity, %{"id" => id}) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.unlink_identity(user, session_token, id) do
      {:ok, identity} ->
        socket
        |> assign_mfa()
        |> put_flash(
          :info,
          "#{identity.provider.display_name} is disconnected from your account."
        )

      {:error, :last_sign_in_method} ->
        put_flash(
          socket,
          :error,
          "That's your only way to sign in. Connect another identity provider first."
        )

      {:error, :last_recheck_method} ->
        put_flash(
          socket,
          :error,
          "Add a password or passkey before disconnecting your last identity provider. You need one of them to confirm it's you."
        )

      {:error, _reason} ->
        put_flash(socket, :error, "The identity provider could not be disconnected.")
    end
  end

  defp apply_change(socket, :recovery_codes, _params) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    case Accounts.regenerate_recovery_codes(user, session_token) do
      {:ok, codes} ->
        socket
        |> assign(:new_recovery_codes, codes)
        |> assign_mfa()

      {:error, _reason} ->
        put_flash(socket, :error, "New recovery codes could not be generated.")
    end
  end

  defp assign_mfa(socket) do
    user = socket.assigns.current_scope.user

    socket
    |> assign(:has_password, not is_nil(user.hashed_password))
    |> assign(:passkeys, Accounts.list_passkeys(user))
    |> assign(:mfa, MFA.mfa?(user))
    |> assign(:totp_available, MFA.totp_available?())
    |> assign(:totp_enabled, MFA.totp_enabled?(user))
    |> assign(:recovery_codes_left, MFA.recovery_codes_left(user))
    |> assign(:recovering, Accounts.recovering?(user, socket.assigns.session_token))
    |> assign(:security_events, Accounts.list_security_events(user))
    |> assign(:identities, Accounts.list_user_identities(user))
    |> assign(:linkable_providers, Accounts.linkable_providers(user))
  end

  # With an authenticator app too, a passkey error shows on the code field;
  # a passkey-only panel shows it by itself.
  defp passkey_errors(%{methods: methods, form: form}) do
    if :totp in methods, do: [], else: Keyword.get_values(form.errors, :code)
  end

  defp passkey_form, do: to_form(%{"name" => "Passkey"}, as: "passkey")

  defp email_initialization_form(params), do: to_form(params, as: "email_initialization")

  defp email_initialization_error(socket, :invalid_code),
    do: email_initialization_code_error(socket, "That code isn't right.")

  defp email_initialization_error(socket, :email_in_use) do
    socket
    |> assign(:email_initialization, nil)
    |> put_flash(:error, "That address now belongs to another account. Choose another.")
  end

  defp email_initialization_error(socket, :not_available) do
    socket
    |> assign(:email_initialization, nil)
    |> put_flash(:error, "This account already has a login email or a way to sign in.")
  end

  defp email_initialization_error(socket, _expired_or_too_many),
    do: email_initialization_code_error(socket, "That code has expired. Send a new one.")

  defp email_initialization_code_error(socket, message) do
    form =
      to_form(%{"code" => ""}, as: "email_initialization", errors: [code: {message, []}])

    update(socket, :email_initialization, &%{&1 | form: form})
  end

  defp recheck_form, do: to_form(%{}, as: "recheck")

  defp recheck_error(%{assigns: %{recheck: nil}} = socket, _field, _message), do: socket

  defp recheck_error(socket, field, message) do
    form = to_form(%{to_string(field) => ""}, as: "recheck", errors: [{field, {message, []}}])
    update(socket, :recheck, &%{&1 | form: form})
  end
end
