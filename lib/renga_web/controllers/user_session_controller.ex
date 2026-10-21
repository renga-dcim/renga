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

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

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
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # The settings page runs the account re-check before it submits here; this
  # checks again because the form post is its own request.
  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user

    with true <-
           Accounts.authorized_account_change?(
             user,
             get_session(conn, :user_token),
             :set_password
           ),
         {:ok, {_user, expired_tokens}} <- Accounts.update_user_password(user, user_params) do
      # disconnect all existing LiveViews with old sessions
      UserAuth.disconnect_sessions(expired_tokens)

      conn
      |> put_session(:user_return_to, ~p"/users/settings")
      |> create(params, "Password updated successfully!")
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
