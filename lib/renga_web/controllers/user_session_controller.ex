defmodule RengaWeb.UserSessionController do
  use RengaWeb, :controller

  alias Renga.Accounts
  alias RengaWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        if user_params["add_passkey"] == "true",
          do: sign_in_to_add_passkey(conn, user, user_params, info),
          else: sign_in(conn, user, user_params, info)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      sign_in(conn, user, user_params, info)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # The link just proved control of the account's email, for the purpose of
  # adding its first credential, so it also grants RFD 19's five-minute
  # bootstrap in this browser: a new account can register with only a
  # passkey. An account that has any credential by the time the session is
  # issued signs in the usual way instead, second step included. Staying
  # signed in follows the person's own choice.
  defp sign_in_to_add_passkey(conn, user, params, info) do
    return_to = get_session(conn, :user_return_to)

    case UserAuth.log_in_user_to_bootstrap(conn, user, params) do
      {:ok, conn} ->
        conn
        |> put_flash(:info, "Email confirmed. Add your passkey now.")
        |> redirect(to: ~p"/users/settings#passkey_register")

      # The attempt cleared the session; only where to go next carries over.
      {:error, conn} ->
        conn
        |> then(&if(return_to, do: put_session(&1, :user_return_to, return_to), else: &1))
        |> sign_in(user, params, info)
    end
  end

  # A password or magic link is the whole sign-in only for an account without
  # MFA; otherwise it is the first step (RFD 19).
  defp sign_in(conn, user, params, info) do
    if Accounts.mfa?(user) do
      UserAuth.begin_second_step(conn, user, params)
    else
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, params)
    end
  end

  # A passkey is two factors by itself (RFD 19), so it signs in directly.
  def passkey(conn, %{"passkey" => %{"response" => response}}) do
    with {:ok, response} when is_map(response) <- Jason.decode(response),
         %Accounts.User{} = user <- Accounts.get_user_by_passkey(response) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, %{"remember_me" => "true"})
    else
      _ ->
        conn
        |> put_flash(:error, "That passkey didn't work.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def second_step(conn, %{"second_step" => %{"passkey" => response}}) do
    case Jason.decode(response) do
      {:ok, response} when is_map(response) -> finish_second_step(conn, {:passkey, response})
      _ -> finish_second_step(conn, :invalid)
    end
  end

  def second_step(conn, %{"second_step" => %{"code" => code}}),
    do: finish_second_step(conn, code)

  defp finish_second_step(conn, credential) do
    case UserAuth.pending_second_step_user(conn) do
      nil ->
        conn
        |> put_flash(:error, "That sign-in expired. Sign in again.")
        |> redirect(to: ~p"/users/log-in")

      user ->
        case verify_second_step(user, credential) do
          {:ok, method} when method in [:totp, :passkey] ->
            conn
            |> put_flash(:info, "Welcome back!")
            |> complete_sign_in(user, method)

          {:ok, :recovery_code} ->
            conn
            |> put_flash(
              :info,
              "You used a recovery code. Add a new authenticator app now; you have five minutes."
            )
            |> complete_sign_in(user, :recovery_code)

          {:error, :rate_limited} ->
            conn
            |> put_flash(:error, "Too many wrong codes. Try again later.")
            |> redirect(to: ~p"/users/log-in/second-step")

          {:error, _reason} ->
            conn
            |> put_flash(:error, "That didn't work. Try again.")
            |> redirect(to: ~p"/users/log-in/second-step")
        end
    end
  end

  defp verify_second_step(_user, :invalid), do: {:error, :invalid_response}
  defp verify_second_step(user, credential), do: Accounts.verify_second_step(user, credential)

  defp complete_sign_in(conn, user, method) do
    case UserAuth.complete_second_step(conn, user, method) do
      {:ok, conn} ->
        conn

      {:error, conn} ->
        conn
        |> put_flash(:error, "That sign-in expired. Sign in again.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # The settings page runs the account re-check before it submits here; this
  # checks again because the form post is its own request.
  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    with true <-
           Accounts.authorized_account_change?(
             user,
             get_session(conn, :user_token),
             :set_password
           ),
         {:ok, {user, expired_tokens}} <- Accounts.update_user_password(user, user_params) do
      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      # This browser already finished signing in, second step included, so
      # it signs straight back in rather than through `create/2`.
      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> put_flash(:info, "Password updated successfully!")
      |> UserAuth.log_in_user(user, user_params)
    else
      false ->
        conn
        |> put_flash(:error, "Confirm it's you before changing your password.")
        |> redirect(to: ~p"/users/settings")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "The password could not be saved.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
