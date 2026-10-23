defmodule Renga.Accounts.GitHub do
  @moduledoc """
  Sign-in through GitHub (RFD 15, "Sign-in flow"). GitHub is an OAuth 2.0
  provider, not an OpenID Connect one, so this small adapter on `Req` does
  the code exchange and reads the account from GitHub's user and email APIs
  instead of an ID token.

  It returns claims shaped like an ID token's, so the rest of sign-in treats
  both kinds alike: `sub` is GitHub's stable numeric user ID, never the
  login name, which people can change; `email` is the primary address, and
  `email_verified` whether GitHub verified it.

  `Renga.Accounts.OIDC` calls `authorize/4` and `exchange/5` for providers of
  kind `github`, so attempts, their binding, and test sign-ins work the same
  way. GitHub cannot show that an authentication is fresh, so a GitHub
  identity never passes the account re-check and a GitHub provider never
  creates an account.
  """

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"
  @api_url "https://api.github.com"
  @scopes ["read:user", "user:email"]

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviders

  @doc """
  The authorization URL for `revision` of `provider`, with a fresh attempt
  holding its `state` and PKCE verifier. GitHub has no nonce.
  """
  def authorize(
        %IdentityProvider{kind: "github"} = provider,
        %Revision{} = revision,
        redirect_uri
      ) do
    attempt = %{
      "provider" => provider.id,
      "revision" => revision.number,
      "state" => random(),
      "verifier" => random(),
      "started_at" => System.system_time(:second),
      "iss_required" => false
    }

    query =
      URI.encode_query(%{
        "client_id" => revision.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => Enum.join(Enum.uniq(@scopes ++ revision.scopes), " "),
        "state" => attempt["state"],
        "code_challenge" => challenge(attempt["verifier"]),
        "code_challenge_method" => "S256",
        "allow_signup" => "false"
      })

    {:ok, @authorize_url <> "?" <> query, attempt}
  end

  @doc """
  Exchanges the callback's code and reads the GitHub account. The caller
  has already matched the callback's state to the attempt, and spent it.
  Returns the provider, the revision, and the account as claims.
  """
  def exchange(
        %IdentityProvider{kind: "github"} = provider,
        %Revision{} = revision,
        attempt,
        params,
        redirect_uri
      ) do
    with :ok <- check_response(params),
         {:ok, secret} <- secret(revision),
         {:ok, access_token} <- token(revision, secret, attempt, params, redirect_uri),
         {:ok, user} <- get(access_token, "/user"),
         {:ok, subject} <- subject(user) do
      claims =
        access_token
        |> primary_email()
        |> Map.merge(%{"sub" => subject, "preferred_username" => user["login"]})

      {:ok, %{provider: provider, revision: revision, claims: claims}}
    end
  end

  defp check_response(params) do
    cond do
      Map.has_key?(params, "error") -> {:error, :denied}
      not is_binary(params["code"]) -> {:error, :invalid_response}
      true -> :ok
    end
  end

  defp secret(revision) do
    case IdentityProviders.client_secret(revision) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> {:error, :secret_unavailable}
    end
  end

  defp token(revision, secret, attempt, params, redirect_uri) do
    request(
      method: :post,
      url: @token_url,
      headers: [{"accept", "application/json"}],
      form: [
        client_id: revision.client_id,
        client_secret: secret,
        code: params["code"],
        redirect_uri: redirect_uri,
        code_verifier: attempt["verifier"]
      ]
    )
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      # GitHub answers a refused exchange with 200 and an `error` field.
      {:ok, _response} ->
        {:error, :invalid_response}

      {:error, _exception} ->
        {:error, :provider_unavailable}
    end
  end

  defp get(access_token, path) do
    request(
      method: :get,
      url: @api_url <> path,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer " <> access_token},
        {"x-github-api-version", "2022-11-28"}
      ]
    )
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, _response} -> {:error, :invalid_response}
      {:error, _exception} -> {:error, :provider_unavailable}
    end
  end

  defp subject(%{"id" => id}) when is_integer(id) and id > 0, do: {:ok, Integer.to_string(id)}
  defp subject(_user), do: {:error, :invalid_claims}

  # Only the primary address is the account's email. Without the
  # `user:email` scope's answer there is none, which allowlists refuse.
  defp primary_email(access_token) do
    with {:ok, emails} when is_list(emails) <- get(access_token, "/user/emails"),
         %{"email" => email} = primary when is_binary(email) <-
           Enum.find(emails, &(is_map(&1) and &1["primary"] == true)) do
      %{"email" => email, "email_verified" => primary["verified"] == true}
    else
      _none -> %{}
    end
  end

  # Responses are never logged: they carry the access token.
  defp request(options) do
    [redirect: false, retry: false, receive_timeout: :timer.seconds(10)]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:renga, :oidc_req_options, []))
    |> Req.request()
  end

  defp challenge(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
