defmodule RengaWeb.UserAuth do
  @moduledoc """
  Authentication plugs and LiveView mount hooks for user sessions.
  """

  use RengaWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Renga.Accounts
  alias Renga.Accounts.Scope
  alias Renga.Accounts.SessionMFA

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_renga_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]
  @current_organization_key :current_organization_id
  @second_step_key :pending_second_step

  # The organization this browser last opened, so signing in again returns
  # to it. It only suggests: sign-in still checks the user may open it. The
  # value names the user who opened it, so someone else signing in on a
  # shared browser is not steered into that person's organization, and is
  # encrypted so it does not reveal either id to the next person.
  @last_organization_cookie "_renga_web_last_organization"
  @last_organization_options [
    encrypt: true,
    max_age: 365 * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in. `method` is how a fresh sign-in authenticated, such as
  `"password"`, for the security log.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`. A fresh session opens the
  organization this browser last opened, or the user's only one, so they
  skip the organization picker (`Renga.Accounts.default_organization_id/2`).
  A return-to link that could name a record opens only a sole organization.
  `expires_at` carries an absolute provider deadline only when replacing an
  existing session after an account change.
  """
  def log_in_user(conn, user, params \\ %{}, method \\ nil, expires_at \\ nil) do
    user_return_to = get_session(conn, :user_return_to)

    # A fresh sign-in names its `method`, and the session and its security
    # log entry commit together. Signing back in after a password change
    # is not a new sign-in and passes none; the new session keeps the MFA
    # evidence and absolute deadline of the one it replaces.
    issue =
      if method,
        do: &Accounts.create_signed_in_session(user, &1, method),
        else:
          &{:ok,
           Accounts.generate_user_session_token(user, &1, expires_at, carried_mfa(conn, user))}

    case create_or_extend_session(conn, user, params, issue) do
      {:ok, signed_in} ->
        signed_in
        |> put_default_organization(user, user_return_to)
        |> redirect(to: user_return_to || signed_in_path(conn))

      # The local sign-in policy refused the method as the session was
      # issued, such as when an override was revoked meanwhile.
      {:error, conn} ->
        conn
        |> put_flash(:error, "That way of signing in isn't available right now.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp carried_mfa(conn, %Accounts.User{id: user_id}) do
    case conn.assigns[:current_scope] do
      %Scope{user: %Accounts.User{id: ^user_id, session_mfa: mfa}} -> mfa
      _ -> nil
    end
  end

  defp put_default_organization(conn, user, user_return_to) do
    if get_session(conn, @current_organization_key) do
      conn
    else
      conn = fetch_cookies(conn, encrypted: [@last_organization_cookie])
      remembered_id = remembered_organization_id(conn, user, user_return_to)

      case Accounts.default_organization_id(user, remembered_id) do
        nil -> conn
        organization_id -> put_session(conn, @current_organization_key, organization_id)
      end
    end
  end

  defp remembered_organization_id(conn, %Accounts.User{id: user_id}, user_return_to) do
    case conn.cookies[@last_organization_cookie] do
      {^user_id, organization_id} ->
        if names_no_record?(conn, user_return_to), do: organization_id

      _absent_or_someone_elses ->
        nil
    end
  end

  # Whether a return-to path cannot name a record. One that can, through a
  # path parameter or the query string, may belong to another of the user's
  # organizations than the remembered one, and opening it there would not
  # find the record; so for it sign-in opens only a sole organization, and
  # anyone with several chooses. Pages such as /inbox are left behind as the
  # return-to path whenever logging out reloads another tab, or a bookmark
  # outlives the session, so they still reopen the remembered organization.
  defp names_no_record?(_conn, nil), do: true

  defp names_no_record?(conn, return_to) do
    case URI.parse(return_to) do
      %URI{scheme: nil, host: nil, path: "/" <> _ = path, query: nil, fragment: nil} ->
        segments = path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

        case Phoenix.Router.route_info(RengaWeb.Router, "GET", segments, conn.host) do
          %{path_params: path_params} -> map_size(path_params) == 0
          :error -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Starts the second step of signing in for an account with MFA (RFD 19).

  A password or magic link only proves the first factor. The half-finished
  sign-in is kept in a fresh session for this browser, expires after five
  minutes, and grants nothing until `complete_second_step/3`.
  """
  def begin_second_step(conn, user, params \\ %{}) do
    pending = %{
      "token" => Base.url_encode64(Accounts.create_pending_second_step(user)),
      "remember_me" => params["remember_me"] == "true",
      "return_to" => get_session(conn, :user_return_to)
    }

    # Starting a sign-in ends whatever this browser was signed in as, so a
    # half-finished sign-in is never also a session through a leftover
    # session or remember-me cookie.
    revoke_browser_session(conn)

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> put_session(@second_step_key, pending)
    |> redirect(to: ~p"/users/log-in/second-step")
  end

  @doc """
  The user a half-finished sign-in belongs to, while its server-side record
  is unspent and current. Takes a conn or a LiveView session.
  """
  def pending_second_step_user(%Plug.Conn{} = conn),
    do:
      pending_second_step_user(%{
        to_string(@second_step_key) => get_session(conn, @second_step_key)
      })

  def pending_second_step_user(session) when is_map(session) do
    with token when is_binary(token) <- pending_second_step_token(session) do
      Accounts.get_pending_second_step_user(token)
    end
  end

  defp pending_second_step_token(session) do
    with %{"token" => encoded} <- session[to_string(@second_step_key)],
         {:ok, token} <- Base.url_decode64(encoded) do
      token
    else
      _ -> nil
    end
  end

  @doc """
  Finishes a sign-in whose second step passed, spending its pending record
  first so it finishes once. A recovery code signs the person in to add a
  replacement factor first. Returns `{:error, conn}` when the pending
  sign-in was already spent or revoked.
  """
  def complete_second_step(conn, user, method) do
    pending = get_session(conn, @second_step_key)
    token = pending_second_step_token(%{to_string(@second_step_key) => pending})
    params = if pending["remember_me"], do: %{"remember_me" => "true"}, else: %{}

    return_to =
      if method == :recovery_code, do: ~p"/users/settings", else: pending["return_to"]

    # The pending sign-in is spent, and the session issued, in one locked
    # transaction, so a password change either ends the new session or
    # leaves nothing to finish.
    issue = fn browser_session_id ->
      if token,
        do: Accounts.finish_pending_second_step(user, token, browser_session_id, method),
        else: :error
    end

    case create_or_extend_session(conn, user, params, issue) do
      {:ok, conn} ->
        {:ok,
         conn
         |> put_default_organization(user, return_to)
         |> redirect(to: return_to || signed_in_path(conn))}

      {:error, conn} ->
        {:error, delete_session(conn, @second_step_key)}
    end
  end

  @doc """
  Signs in through an identity provider, once `Renga.Accounts.OIDC.finish/3`
  validated the callback (RFD 15). The account is resolved and the session
  issued while the provider is locked against changes, and the session ends
  when the provider's session lifetime does, however active it is. Returns
  the conn with the new session and where to send the browser; nothing is
  sent until the caller redirects, after it all committed.
  """
  def log_in_user_with_provider(conn, %{provider: provider, revision: revision} = result) do
    user_return_to = get_session(conn, :user_return_to)
    method = "provider:#{provider.id}"

    deadline =
      DateTime.add(Renga.Time.utc_now_ms(), revision.session_lifetime_seconds, :second)

    # Runs inside the sign-in transaction, so the tokens it deletes are only
    # announced once that commits; a rolled-back deletion announces nothing.
    issue = fn user ->
      case issue_session(
             conn,
             user,
             %{},
             &Accounts.create_signed_in_session(
               user,
               &1,
               method,
               deadline,
               SessionMFA.for_provider(provider, result.claims)
             )
           ) do
        {:ok, conn, revoked} -> {:ok, {conn, revoked, user}}
        {:error, _conn, _revoked} -> {:error, :session_failed}
      end
    end

    # The browser's earlier session ends first, committed and announced on
    # its own: revoked inside the sign-in transaction, its disconnect would
    # go out before the deletion commits, and a page mounted in between
    # would keep the old session. A sign-in that then fails leaves the
    # browser signed out.
    revoke_browser_session(conn)

    with {:ok, {conn, revoked, user}} <- Accounts.finish_provider_sign_in(result, issue) do
      # Tokens issued to this browser after the revocation above, such as
      # by a sign-in finishing alongside this one.
      disconnect_tokens(revoked)

      {:ok, put_default_organization(conn, user, user_return_to),
       user_return_to || signed_in_path(conn)}
    end
  end

  @doc """
  Signs in a person who just proved control of the email to add a first
  credential, with the bootstrap authorization (RFD 19). Nothing is written
  to the response unless the session and its grant were committed together;
  `{:error, conn}` means the account is no longer eligible.
  """
  def log_in_user_to_bootstrap(conn, user, params \\ %{}) do
    create_or_extend_session(conn, user, params, &Accounts.create_bootstrap_session(user, &1))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    revoke_browser_session(conn)

    if live_socket_id = get_session(conn, :live_socket_id) do
      RengaWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(
        :current_scope,
        Accounts.scope_for_user(user, get_session(conn, @current_organization_key))
      )
      |> ensure_browser_session_id(token)
      |> maybe_extend_user_session_token(token, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  @doc """
  Stores the current organization in the session and refreshes `current_scope`,
  and remembers it in this browser for the next sign-in.
  """
  def put_current_organization(conn, organization_id) when is_binary(organization_id) do
    with %Scope{user: %Accounts.User{} = user} <- conn.assigns[:current_scope],
         %Scope{} = scope <- Accounts.scope_for_user(user, organization_id),
         true <- opens?(scope, organization_id) do
      conn
      |> put_session(@current_organization_key, organization_id)
      |> put_resp_cookie(
        @last_organization_cookie,
        {user.id, organization_id},
        @last_organization_options
      )
      |> assign(:current_scope, scope)
    else
      _ -> conn
    end
  end

  def put_current_organization(conn, %{id: organization_id}) when is_binary(organization_id) do
    put_current_organization(conn, organization_id)
  end

  # A member whose session must first confirm a second factor (RFD 19)
  # still selects the organization, so it opens once they confirm.
  defp opens?(%Scope{organization_id: id}, id), do: true
  defp opens?(%Scope{mfa_organization: %{id: id}}, id), do: true
  defp opens?(_scope, _organization_id), do: false

  @doc """
  Clears the selected organization from the session and refreshes `current_scope`.
  """
  def clear_current_organization(conn) do
    scope =
      case conn.assigns[:current_scope] do
        %Scope{user: %Accounts.User{} = user} -> Scope.for_user(user)
        _ -> nil
      end

    conn
    |> delete_session(@current_organization_key)
    |> assign(:current_scope, scope)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # A session restored from the remember-me cookie, or one signed in before
  # browser sessions were recorded, learns its browser session id here.
  defp ensure_browser_session_id(conn, token) do
    if get_session(conn, :browser_session_id) do
      conn
    else
      put_session(conn, :browser_session_id, Accounts.ensure_browser_session_id(token))
    end
  end

  # Renew the session token in place once it is older than the renewal age,
  # and refresh the remember-me cookie with it. The token itself never
  # changes, so concurrent requests cannot leave two live sessions behind.
  defp maybe_extend_user_session_token(conn, token, token_inserted_at) do
    token_age = DateTime.diff(Renga.Time.utc_now_ms(), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      :ok = Accounts.extend_user_session_token(token)
      maybe_write_remember_me_cookie(conn, token, %{}, get_session(conn, :user_remember_me))
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens and
  # storing them safely in the session and cookies, when logging in and after
  # a password change.
  #
  # A browser session is one `:browser_session_id` in the signed session,
  # recorded on each token issued to it. Signing in again first revokes every
  # token of that browser session, so evidence bound to an earlier token,
  # such as the account re-check (RFD 19), cannot outlive it, and LiveViews
  # still connected with it disconnect. It keeps the id when the same user
  # signs in again, so a late response that writes the earlier token back
  # cannot hide the new one from sign-out. A different user gets a fresh
  # session and id through renew_session, against fixation.
  #
  # `issue` creates the token for the browser session id; the second step
  # passes one that issues it only while the pending sign-in is unspent.
  defp create_or_extend_session(conn, user, params, issue) do
    # Outside any transaction the deletion has committed by now, so the
    # disconnect can go out.
    {result, conn, revoked} =
      case issue_session(conn, user, params, issue) do
        {:ok, conn, revoked} -> {:ok, conn, revoked}
        {:error, conn, revoked} -> {:error, conn, revoked}
      end

    disconnect_tokens(revoked)
    {result, conn}
  end

  # Revokes the browser's session and issues the new one, returning the
  # revoked tokens for the caller to disconnect once their deletion commits.
  defp issue_session(conn, user, params, issue) do
    issue = issue || (&{:ok, Accounts.generate_user_session_token(user, &1)})
    revoked = delete_browser_session(conn)
    remember_me = get_session(conn, :user_remember_me)
    conn = renew_session(conn, user)
    browser_session_id = get_session(conn, :browser_session_id) || Ecto.UUID.generate()

    case issue.(browser_session_id) do
      {:ok, token} ->
        {:ok,
         conn
         |> put_session(:browser_session_id, browser_session_id)
         |> put_token_in_session(token)
         |> maybe_write_remember_me_cookie(token, params, remember_me), revoked}

      :error ->
        {:error, conn, revoked}
    end
  end

  defp revoke_browser_session(conn) do
    conn |> delete_browser_session() |> disconnect_tokens()
    :ok
  end

  # Deletes every token of this browser's session and returns them, without
  # telling their LiveViews yet.
  defp delete_browser_session(conn) do
    token = get_session(conn, :user_token)
    browser_session_id = get_session(conn, :browser_session_id)

    if token || browser_session_id do
      {:ok, tokens} = Accounts.delete_browser_session_tokens(token, browser_session_id)
      Enum.uniq(List.wrap(token) ++ tokens)
    else
      []
    end
  end

  defp disconnect_tokens(tokens), do: disconnect_sessions(Enum.map(tokens, &%{token: &1}))

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      RengaWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule RengaWeb.PageLive do
        use RengaWeb, :live_view

        on_mount {RengaWeb.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{RengaWeb.UserAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_organization, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{organization_id: organization_id} when is_binary(organization_id) ->
        {:cont, attach_organization_guard(socket)}

      # The organization requires MFA and this session has not shown a
      # second factor yet: ask for one in place (RFD 19).
      %Scope{mfa_organization: %{}} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/organizations/confirm-mfa")}

      _no_organization ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Select an organization to view inventory.")
          |> Phoenix.LiveView.redirect(to: ~p"/organizations")

        {:halt, socket}
    end
  end

  defp attach_organization_guard(socket) do
    socket
    |> Phoenix.LiveView.attach_hook(:organization_access, :handle_event, fn
      _event, _params, socket -> refresh_organization(socket)
    end)
    |> Phoenix.LiveView.attach_hook(:organization_access, :handle_params, fn
      _params, _uri, socket -> refresh_organization(socket)
    end)
    |> Phoenix.LiveView.attach_hook(:organization_access, :handle_info, fn
      _message, socket -> refresh_organization(socket)
    end)
    |> Phoenix.LiveView.attach_hook(:organization_access, :handle_async, fn
      _name, _result, socket -> refresh_organization(socket)
    end)
  end

  # A LiveView can outlive both a newly enabled requirement and removal of a
  # provider's MFA mark. Refresh before every organization interaction so the
  # next request observes current membership, permissions, and MFA policy.
  defp refresh_organization(%{assigns: %{current_scope: current_scope}} = socket) do
    scope = Accounts.scope_for_user(current_scope.user, current_scope.organization_id)

    case scope do
      %Scope{organization_id: organization_id} when is_binary(organization_id) ->
        {:cont, Phoenix.Component.assign(socket, :current_scope, scope)}

      %Scope{mfa_organization: %{}} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/organizations/confirm-mfa")}

      _no_organization ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Select an organization to view inventory.")
         |> Phoenix.LiveView.redirect(to: ~p"/organizations")}
    end
  end

  defp mount_current_scope(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Accounts.scope_for_user(user, session[to_string(@current_organization_key)])
    end)
    |> end_at_session_deadline(session["user_token"])
  end

  # A connected LiveView outlives the request that checked its session, so
  # one whose session has a deadline (a provider sign-in) leaves at it.
  defp end_at_session_deadline(socket, token) when is_binary(token) do
    # Both the authentication and the organization hooks get here; the
    # deadline is set up once per socket.
    with true <- Phoenix.LiveView.connected?(socket),
         false <- Map.has_key?(socket.assigns, :session_deadline),
         %Scope{user: %Accounts.User{}} <- socket.assigns.current_scope,
         %DateTime{} = deadline <- Accounts.session_deadline(token) do
      Process.send_after(
        self(),
        :session_deadline,
        max(DateTime.diff(deadline, Renga.Time.utc_now_ms(), :millisecond), 0)
      )

      socket
      |> Phoenix.Component.assign(:session_deadline, deadline)
      |> Phoenix.LiveView.attach_hook(:session_deadline, :handle_info, fn
        :session_deadline, socket ->
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(:error, "Your session ended. Please log in again.")
           |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")}

        _message, socket ->
          {:cont, socket}
      end)
    else
      _no_deadline -> socket
    end
  end

  defp end_at_session_deadline(socket, _token), do: socket

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/users/settings"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
