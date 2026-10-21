defmodule Renga.Accounts.OIDC do
  @moduledoc """
  Sign-in through an OpenID Connect provider (RFD 15, "Sign-in flow").

  `oidcc` supplies discovery, the token exchange, and ID token validation:
  signature, issuer, audience, expiry, and nonce. Renga binds each attempt
  itself. `start/3` returns the provider's authorization URL and an attempt
  holding a fresh `state`, `nonce`, and PKCE verifier, which the caller keeps
  in the browser session; `finish/3` accepts a callback only for that
  attempt, and only while the provider still uses the revision the attempt
  started with.
  """

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OIDC.Discovery
  alias Renga.Accounts.OIDC.HTTP

  @attempt_seconds 10 * 60
  @default_scopes ["openid", "email", "profile"]

  @doc """
  Starts signing in with `provider`. Returns `{:ok, url, attempt}`; send the
  browser to `url` and keep `attempt` for the callback.
  """
  def start(%IdentityProvider{kind: "oidc"} = provider, redirect_uri, opts \\ []) do
    with %Revision{} = revision <-
           IdentityProviders.active_revision(provider) || {:error, :inactive},
         true <- IdentityProviders.usable?(provider) || {:error, :inactive},
         {:ok, context} <- client_context(provider, revision) do
      attempt = %{
        "provider" => provider.id,
        "revision" => revision.number,
        "state" => random(),
        "nonce" => random(),
        "verifier" => random(),
        "started_at" => System.system_time(:second)
      }

      authorization =
        %{
          redirect_uri: redirect_uri,
          state: attempt["state"],
          nonce: attempt["nonce"],
          pkce_verifier: attempt["verifier"],
          require_pkce: true,
          scopes: Enum.uniq(@default_scopes ++ revision.scopes),
          request_opts: HTTP.request_opts()
        }
        |> put_extension(opts[:url_extension])

      with {:ok, url} <- Oidcc.Authorization.create_redirect_url(context, authorization) do
        {:ok, IO.iodata_to_binary(url), attempt}
      end
    end
  end

  @doc """
  Finishes an attempt from the provider's callback parameters. Returns the
  provider, the revision used, and the validated ID token claims.
  """
  def finish(attempt, params, redirect_uri) when is_map(attempt) and is_map(params) do
    with :ok <- check_state(attempt, params),
         :ok <- check_age(attempt),
         {:ok, provider, revision} <- current(attempt),
         :ok <- check_response(provider, params),
         {:ok, context} <- client_context(provider, revision),
         {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} <-
           Oidcc.Token.retrieve(params["code"], context, %{
             redirect_uri: redirect_uri,
             nonce: attempt["nonce"],
             pkce_verifier: attempt["verifier"],
             require_pkce: true,
             refresh_jwks: &refresh_jwks(provider, &1, &2),
             request_opts: HTTP.request_opts()
           }) do
      {:ok, %{provider: provider, revision: revision, claims: claims}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _detail} -> {:error, :invalid_response}
    end
  end

  def finish(_attempt, _params, _redirect_uri), do: {:error, :no_attempt}

  defp check_state(%{"state" => expected}, %{"state" => given})
       when is_binary(expected) and is_binary(given) do
    if Plug.Crypto.secure_compare(expected, given), do: :ok, else: {:error, :state_mismatch}
  end

  defp check_state(_attempt, _params), do: {:error, :state_mismatch}

  defp check_age(%{"started_at" => started_at}) when is_integer(started_at) do
    if System.system_time(:second) - started_at <= @attempt_seconds,
      do: :ok,
      else: {:error, :expired}
  end

  defp check_age(_attempt), do: {:error, :expired}

  # The attempt completes only against the configuration it started with: a
  # provider disabled, removed, or given a new active revision in between
  # makes the callback fail rather than run under different settings.
  defp current(%{"provider" => id, "revision" => number}) do
    with %IdentityProvider{} = provider <- IdentityProviders.get(id) || {:error, :inactive},
         true <- IdentityProviders.usable?(provider) || {:error, :inactive},
         true <- provider.active_revision == number || {:error, :provider_changed} do
      {:ok, provider, IdentityProviders.active_revision(provider)}
    end
  end

  # An error from the provider, a code that is missing, or an `iss` naming
  # another issuer (RFC 9207, against mix-up attacks) ends the attempt.
  defp check_response(provider, params) do
    cond do
      is_binary(params["error"]) -> {:error, :denied}
      not is_binary(params["code"]) -> {:error, :invalid_response}
      is_binary(params["iss"]) and params["iss"] != provider.issuer -> {:error, :issuer_mismatch}
      true -> :ok
    end
  end

  defp client_context(provider, revision) do
    with {:ok, configuration, jwks} <- Discovery.fetch(provider.issuer),
         {:ok, secret} <- IdentityProviders.client_secret(revision) do
      {:ok, Oidcc.ClientContext.from_manual(configuration, jwks, revision.client_id, secret)}
    else
      {:error, reason} when reason in [:no_secret, :invalid, :unknown_key] ->
        {:error, :secret_unavailable}

      {:error, _detail} ->
        {:error, :provider_unavailable}
    end
  end

  # oidcc calls this from Erlang, which expects the key set as a record.
  defp refresh_jwks(provider, _jwks, _kid) do
    with {:ok, jwks} <- Discovery.refresh_jwks(provider.issuer),
         do: {:ok, JOSE.JWK.to_record(jwks)}
  end

  defp put_extension(authorization, nil), do: authorization

  defp put_extension(authorization, extension),
    do: Map.put(authorization, :url_extension, extension)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
