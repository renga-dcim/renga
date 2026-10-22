defmodule RengaWeb.UserLive.Settings do
  @moduledoc """
  Account settings. The page opens without signing in again; saving a change
  that could take over the account asks for the account re-check in place
  (RFD 19), and the change goes through once it passes.
  """

  use RengaWeb, :live_view

  alias Renga.Accounts

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
        description="The email you sign in with and an optional password."
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

  defp bootstrap?(%{methods: [], change: :set_password}), do: true
  defp bootstrap?(_recheck), do: false

  defp recheck_description(%{methods: [:password | _]}),
    do:
      "Enter your current password. It covers changes to your sign-in for the next five minutes."

  defp recheck_description(%{methods: [], change: :set_password, code_sent: false}),
    do:
      "Your account has no password yet. We'll email a code to your current address to confirm the first one."

  defp recheck_description(%{methods: [], change: :set_password}),
    do: "Enter the code we emailed to your current address. It expires in five minutes."

  defp recheck_description(%{methods: []}),
    do:
      "Set a password first. Your account needs a way to confirm it's you before its email changes."

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

  defp recheck_form, do: to_form(%{}, as: "recheck")

  defp recheck_error(socket, field, message) do
    form = to_form(%{to_string(field) => ""}, as: "recheck", errors: [{field, {message, []}}])
    update(socket, :recheck, &%{&1 | form: form})
  end
end
