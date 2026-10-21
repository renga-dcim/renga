defmodule RengaWeb.UserProviderController do
  @moduledoc """
  Sign-in through an identity provider (RFD 15). `start` sends the browser to
  the provider with a fresh attempt kept in the session; `callback` accepts
  only that attempt and ends in the same session a password sign-in creates.
  The provider handles its own MFA, so there is no Renga second step (RFD 19).
  """

  use RengaWeb, :controller

  require Logger

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.IdentityProviderTest
  alias Renga.Accounts.OIDC
  alias Renga.Accounts.ProviderTests
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

  @doc """
  Opens a test sign-in link (RFD 15). The test's callback comes back to
  `callback/2` like any other, and activates the tested revision without
  signing anyone in.
  """
  def test(conn, %{"token" => token}) do
    case ProviderTests.start(token, &callback_url/1) do
      {:ok, url} ->
        redirect(conn, external: url)

      {:error, reason} ->
        conn
        |> put_flash(:error, test_message({:error, reason}))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, params) do
    case ProviderTests.for_state(params["state"]) do
      %IdentityProviderTest{} = test -> finish_test(conn, test, params)
      nil -> finish_sign_in(conn, params)
    end
  end

  # A test only validates and activates the revision. It leaves the browser
  # session as it was: nobody is signed in or out.
  defp finish_test(conn, test, %{"provider" => id} = params) do
    case ProviderTests.finish(test, params, callback_url(id)) do
      {:ok, provider} ->
        conn
        |> put_flash(
          :info,
          "The test sign-in worked, and #{provider.display_name} now uses revision #{provider.active_revision}."
        )
        |> redirect(to: ~p"/users/log-in")

      error ->
        # Only the reason: never the test's secrets, a token, or a changeset.
        Logger.info("Test sign-in through #{id} failed: #{log_reason(error)}")

        conn
        |> put_flash(:error, test_message(error))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp finish_sign_in(conn, %{"provider" => id} = params) do
    attempt = get_session(conn, @attempt_key)
    conn = delete_session(conn, @attempt_key)

    with :ok <- if(match?(%{"provider" => ^id}, attempt), do: :ok, else: {:error, :no_attempt}),
         {:ok, result} <- OIDC.finish(attempt, params, callback_url(id)),
         {:ok, conn, return_to} <- UserAuth.log_in_user_with_provider(conn, result) do
      conn
      |> put_flash(:info, "Welcome back!")
      |> redirect(to: return_to)
    else
      {:error, reason} when is_atom(reason) ->
        # Only the reason: never the attempt, its secrets, or any token.
        Logger.info("Provider sign-in through #{id} failed: #{reason}")

        conn
        |> put_flash(:error, message({:error, reason}))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp log_reason({:error, reason}) when is_atom(reason), do: reason
  defp log_reason(_error), do: :failed

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

  defp test_message({:error, :test_expired}),
    do: "That test link has expired or was already used. Create a new test."

  defp test_message({:error, :revision_changed}),
    do: "The provider's settings changed since this test was created. Test the new settings."

  defp test_message(_error),
    do: "The test sign-in didn't work, so the new settings were not activated."
end
