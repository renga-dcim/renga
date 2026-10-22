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
        <.settings_section
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
          <.recheck_panel :if={@recheck && @recheck.change == :change_email} recheck={@recheck} />
        </.settings_section>

        <.settings_section
          id="account-password"
          title="Password"
          description="Signing in with an emailed link always works; a password is optional."
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
            <.button variant="primary" phx-disable-with="Saving...">
              Save Password
            </.button>
          </.form>
          <.recheck_panel :if={@recheck && @recheck.change == :set_password} recheck={@recheck} />
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

          <div :if={@totp_enabled} class="space-y-3">
            <p id="totp_status" class="text-sm text-fg">
              On. {recovery_codes_text(@recovery_codes_left)}
            </p>
            <div
              :if={@recovering and !@totp_setup}
              id="recovery_notice"
              class="flex gap-2.5 rounded-md bg-info-fill px-3 py-2 text-sm text-fg"
            >
              <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-info" />
              <p>
                You signed in with a recovery code. Replace your authenticator app now; this
                works only for the next few minutes.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <.button
                :if={@recovering and !@totp_setup}
                id="totp_replace"
                variant="primary"
                phx-click="start_totp"
              >
                Replace authenticator app
              </.button>
              <.button id="recovery_regenerate" phx-click="regenerate_recovery_codes">
                Generate new recovery codes
              </.button>
              <.button id="totp_remove" variant="danger" phx-click="remove_totp">
                Remove
              </.button>
            </div>
          </div>

          <div
            :if={@new_recovery_codes}
            id="recovery_codes"
            class="mt-4 space-y-3 rounded-lg border border-edge bg-sunken p-4"
          >
            <div>
              <h3 class="text-sm font-medium text-fg">Recovery codes</h3>
              <p class="mt-1 text-xs text-fg-muted">
                Save these somewhere safe. Each one signs you in once if you lose your
                authenticator app, and they won't be shown again.
              </p>
            </div>
            <ul class="grid grid-cols-2 gap-x-6 gap-y-1 font-mono text-sm text-fg">
              <li :for={code <- @new_recovery_codes}>{code}</li>
            </ul>
            <.button type="button" phx-click="dismiss_recovery_codes">I've saved them</.button>
          </div>

          <.recheck_panel
            :if={@recheck && @recheck.change in [:add_factor, :remove_factor, :recovery_codes]}
            recheck={@recheck}
          />
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

  defp bootstrap?(%{methods: [], change: change}), do: change in [:set_password, :add_factor]
  defp bootstrap?(_recheck), do: false

  defp recheck_description(%{methods: [:totp | _]}),
    do:
      "Enter a code from your authenticator app. It covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [:password | _]}),
    do:
      "Enter your current password. It covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [], code_sent: true}),
    do: "Enter the code we emailed to your current address. It expires in five minutes."

  defp recheck_description(%{methods: []} = recheck) do
    if bootstrap?(recheck),
      do:
        "Your account has no password or authenticator app yet. We'll email a code to your current address to confirm the first one.",
      else:
        "Set a password first. Your account needs a way to confirm it's you before its email changes."
  end

  defp recovery_codes_text(1), do: "1 recovery code left."
  defp recovery_codes_text(count), do: "#{count} recovery codes left."

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

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
      |> assign_mfa()

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
      do: {:noreply, with_recheck(socket, :add_factor, %{})},
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
        {:noreply, with_recheck(socket, :add_factor, %{})}

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
    {:noreply, with_recheck(socket, :remove_factor, %{})}
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

  def handle_event("cancel_recheck", _params, socket) do
    {:noreply, assign(socket, :recheck, nil)}
  end

  # Runs `change` now if this session is already authorized for it, otherwise
  # asks for the re-check and keeps the change to resume afterwards.
  defp with_recheck(socket, change, params) do
    %{current_scope: %{user: user}, session_token: session_token} = socket.assigns

    if Accounts.authorized_account_change?(user, session_token, change) do
      apply_change(socket, change, params)
    else
      assign(socket, :recheck, %{
        change: change,
        params: params,
        methods: Accounts.recheck_methods(user),
        code_sent: false,
        form: recheck_form()
      })
    end
  end

  # A passed check only resumes the pending change through the same
  # authorization test that asked for it, so evidence that cannot authorize
  # that change, such as the email bootstrap for an email change, asks again.
  defp resume(%{assigns: %{recheck: %{change: change, params: params}}} = socket) do
    socket
    |> assign(:recheck, nil)
    |> with_recheck(change, params)
  end

  defp resume(socket), do: socket

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

  defp apply_change(%{assigns: %{totp_setup: nil}} = socket, :add_factor, _params) do
    secret = MFA.new_totp_secret()
    uri = MFA.totp_uri(socket.assigns.current_scope.user, secret)

    assign(socket, :totp_setup, %{
      secret: secret,
      formatted_secret: MFA.format_totp_secret(secret),
      qr_svg: uri |> EQRCode.encode() |> EQRCode.svg(width: 176),
      form: to_form(%{}, as: "totp")
    })
  end

  defp apply_change(socket, :add_factor, _params), do: socket

  defp apply_change(socket, :remove_factor, _params) do
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
    |> assign(:totp_available, MFA.totp_available?())
    |> assign(:totp_enabled, MFA.totp_enabled?(user))
    |> assign(:recovery_codes_left, MFA.recovery_codes_left(user))
    |> assign(:recovering, Accounts.recovering?(user, socket.assigns.session_token))
  end

  defp recheck_form, do: to_form(%{}, as: "recheck")

  defp recheck_error(%{assigns: %{recheck: nil}} = socket, _field, _message), do: socket

  defp recheck_error(socket, field, message) do
    form = to_form(%{to_string(field) => ""}, as: "recheck", errors: [{field, {message, []}}])
    update(socket, :recheck, &%{&1 | form: form})
  end
end
