defmodule RengaWeb.UserProviderController do
  @moduledoc """
  Sign-in through an identity provider (RFD 15). `start` sends the browser to
  the provider with a fresh attempt kept in the session; `callback` accepts
  only that attempt and ends in the same session a password sign-in creates.
  The provider handles its own MFA, so there is no Renga second step (RFD 19).
  """

  use RengaWeb, :controller

  require Logger

  alias Renga.Accounts.Identities
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OIDC
  alias RengaWeb.UserAuth

  @attempt_key :provider_attempt

  def start(conn, %{"provider" => id}) do
    with %{kind: "oidc"} = provider <- IdentityProviders.get(id),
         {:ok, url, attempt} <- OIDC.start(provider, callback_url(id)) do
      conn
      |> put_session(@attempt_key, attempt)
      |> redirect(external: url)
    else
      _unavailable ->
        conn
        |> put_flash(:error, "That sign-in option isn't available right now.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, %{"provider" => id} = params) do
    attempt = get_session(conn, @attempt_key)
    conn = delete_session(conn, @attempt_key)

    with %{"provider" => ^id} <- attempt || {:error, :no_attempt},
         {:ok, result} <- OIDC.finish(attempt, params, callback_url(id)),
         {:ok, user} <- Identities.resolve(result) do
      # The session and its security log entry commit together.
      conn
      |> put_flash(:info, "Welcome back!")
      |> UserAuth.log_in_user(user, %{}, "provider:#{id}")
    else
      error ->
        Logger.info("Provider sign-in through #{id} failed: #{inspect(error)}")

        conn
        |> put_flash(:error, message(error))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp callback_url(id), do: url(~p"/users/auth/#{id}/callback")

  defp message({:error, :email_in_use}),
    do:
      "An account already uses that email. Log in to it another way to connect this sign-in option."

  defp message({:error, :sign_up_closed}),
    do: "No account uses that sign-in yet, and this option doesn't create new accounts."

  defp message({:error, :unverified_email}),
    do: "Your identity provider hasn't verified your email, so Renga can't create an account."

  defp message({:error, :domain_not_allowed}),
    do: "That sign-in option isn't open to your email address."

  defp message({:error, :denied}), do: "Sign-in was cancelled."
  defp message(_error), do: "Sign-in didn't work. Please try again."
end
