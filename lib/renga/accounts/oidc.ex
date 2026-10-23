defmodule Renga.Accounts.OIDC do
  @moduledoc """
  Sign-in through an OpenID Connect provider (RFD 15, "Sign-in flow").

  `oidcc` supplies discovery, the token exchange, and ID token validation:
  signature, issuer, audience, expiry, and nonce. Renga binds each attempt
  itself. `start/2` returns the provider's authorization URL and an attempt
  holding a fresh `state`, `nonce`, and PKCE verifier, which the caller keeps
  in the browser session, and records the state's hash on the server;
  `finish/3` accepts a callback only for that attempt, at most once, and
  only while the provider still uses the revision the attempt started with.

  An attempt has a purpose. A sign-in names nobody; linking the provider to
  an account is bound to the user and the session that started it, and only
  a callback finishing it for that same session can complete it.
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderAttempt
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OIDC.Discovery
  alias Renga.Accounts.OIDC.HTTP
  alias Renga.Repo

  @attempt_seconds 10 * 60
  @default_scopes ["openid", "email", "profile"]
  # How recently a re-check sign-in must have authenticated (RFD 19's
  # re-check window), and how far ahead of this server's clock an
  # `auth_time` may be before it counts as in the future.
  @recheck_max_age 5 * 60
  @clock_skew 60

  @typedoc """
  What an attempt is for: `:sign_in`; `{:link, user_id, session_token_id}`
  to connect the provider to that user's account from that session; or
  `{:recheck, user_id, session_token_id}` to pass the account re-check by
  signing in again.
  """
  @type purpose ::
          :sign_in
          | {:link, Ecto.UUID.t(), Ecto.UUID.t()}
          | {:recheck, Ecto.UUID.t(), Ecto.UUID.t()}

  @doc """
  Starts signing in with `provider`, or another `purpose`. Returns
  `{:ok, url, attempt}`; send the browser to `url` and keep `attempt` for
  the callback. A re-check asks the provider to authenticate the person
  again now, with `prompt=login` and `max_age`.
  """
  def start(%IdentityProvider{kind: "oidc"} = provider, redirect_uri, purpose \\ :sign_in) do
    with %Revision{} = revision <-
           IdentityProviders.active_revision(provider) || {:error, :inactive},
         true <- IdentityProviders.usable?(provider) || {:error, :inactive},
         {:ok, url, attempt} <-
           authorize(provider, revision, redirect_uri, url_extension(purpose)) do
      Repo.insert!(
        struct(
          %IdentityProviderAttempt{
            provider_id: provider.id,
            revision: revision.number,
            state_hash: hash(attempt["state"]),
            expires_at: DateTime.add(Renga.Time.utc_now_ms(), @attempt_seconds, :second)
          },
          attempt_binding(purpose)
        )
      )

      {:ok, url, Map.put(attempt, "purpose", purpose_name(purpose))}
    end
  end

  defp attempt_binding(:sign_in), do: [purpose: "sign_in", user_id: nil, session_token_id: nil]

  defp attempt_binding({purpose, user_id, session_token_id}) when purpose in [:link, :recheck],
    do: [purpose: Atom.to_string(purpose), user_id: user_id, session_token_id: session_token_id]

  defp purpose_name(purpose), do: attempt_binding(purpose)[:purpose]

  defp url_extension({:recheck, _user_id, _session_token_id}),
    do: [{"prompt", "login"}, {"max_age", Integer.to_string(@recheck_max_age)}]

  defp url_extension(_purpose), do: []

  @doc """
  Checks that validated ID token `claims` show a fresh authentication for
  the account re-check (RFD 15, "Re-authentication and step-up"): an
  `auth_time` that is an integer, not in the future, and within the
  re-check window. `oidcc` validates the token but does not age-check
  `auth_time`, so Renga does.
  """
  def fresh_authentication?(%{"auth_time" => auth_time}) when is_integer(auth_time) do
    now = System.system_time(:second)
    auth_time <= now + @clock_skew and now - auth_time <= @recheck_max_age
  end

  def fresh_authentication?(_claims), do: false

  @doc """
  The authorization URL for `revision` of `provider`, whichever revision
  that is, with a fresh attempt. `start/2` uses the active revision and
  records the attempt; a test sign-in uses the pending one and keeps the
  attempt on its own record. `extension` adds query parameters, such as a
  re-check's `prompt`.
  """
  def authorize(
        %IdentityProvider{} = provider,
        %Revision{} = revision,
        redirect_uri,
        extension \\ []
      ) do
    with {:ok, context} <- client_context(provider, revision) do
      attempt = %{
        "provider" => provider.id,
        "revision" => revision.number,
        "state" => random(),
        "nonce" => random(),
        "verifier" => random(),
        "started_at" => System.system_time(:second),
        # RFC 9207: a provider that says it sends `iss` must send it.
        "iss_required" => iss_required?(context)
      }

      authorization = %{
        redirect_uri: redirect_uri,
        state: attempt["state"],
        nonce: attempt["nonce"],
        pkce_verifier: attempt["verifier"],
        require_pkce: true,
        scopes: Enum.uniq(@default_scopes ++ revision.scopes),
        url_extension: extension,
        request_opts: HTTP.request_opts()
      }

      with {:ok, url} <- Oidcc.Authorization.create_redirect_url(context, authorization) do
        {:ok, IO.iodata_to_binary(url), attempt}
      end
    end
  end

  @doc """
  Finishes an attempt from the provider's callback parameters, for the
  `purpose` it started with. Returns the provider, the revision used, and
  the validated ID token claims.
  """
  def finish(attempt, params, redirect_uri, purpose \\ :sign_in)

  def finish(attempt, params, redirect_uri, purpose) when is_map(attempt) and is_map(params) do
    with :ok <- check_state(attempt, params),
         :ok <- check_age(attempt),
         {:ok, provider, revision} <- current(attempt),
         :ok <- check_response(provider, attempt, params),
         :ok <- consume(attempt, purpose) do
      exchange(provider, revision, attempt, params, redirect_uri)
    end
  end

  def finish(_attempt, _params, _redirect_uri, _purpose), do: {:error, :no_attempt}

  @doc """
  Exchanges the callback's code with `revision` of `provider` and validates
  the ID token against the attempt's nonce and PKCE verifier. The caller has
  already matched the callback's state to the attempt, and spent it.
  """
  def exchange(
        %IdentityProvider{} = provider,
        %Revision{} = revision,
        attempt,
        params,
        redirect_uri
      ) do
    with {:ok, context} <- client_context(provider, revision),
         # The provider's current metadata counts too, for an attempt that
         # did not record whether `iss` is required, such as a test's.
         attempt =
           Map.update(
             attempt,
             "iss_required",
             iss_required?(context),
             &(&1 or iss_required?(context))
           ),
         :ok <- check_response(provider, attempt, params),
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
      # Only a reason leaves here: tokens, claims, and the attempt's secrets
      # must not reach a log line or an error report.
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_response}
    end
  end

  defp iss_required?(context),
    do: context.provider_configuration.authorization_response_iss_parameter_supported == true

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

  # An error from the provider, a code that is missing, or an `iss` that
  # names another issuer, is not a string, or is missing from a provider that
  # promised it (RFC 9207, against mix-up attacks) ends the attempt.
  defp check_response(provider, attempt, params) do
    cond do
      Map.has_key?(params, "error") ->
        {:error, :denied}

      not is_binary(params["code"]) ->
        {:error, :invalid_response}

      Map.has_key?(params, "iss") and params["iss"] != provider.issuer ->
        {:error, :issuer_mismatch}

      attempt["iss_required"] == true and not Map.has_key?(params, "iss") ->
        {:error, :issuer_mismatch}

      true ->
        :ok
    end
  end

  # Spends the server's record of the attempt before the code is exchanged,
  # so the attempt finishes at most once, and only for the purpose, user,
  # and session it started with: a sign-in callback cannot finish a link,
  # nor one session finish another's.
  defp consume(%{"provider" => id, "revision" => number, "state" => state}, purpose) do
    now = Renga.Time.utc_now_ms()
    Repo.delete_all(where(IdentityProviderAttempt, [a], a.expires_at < ^now))

    query =
      Enum.reduce(
        attempt_binding(purpose),
        where(IdentityProviderAttempt,
          state_hash: ^hash(state),
          provider_id: ^id,
          revision: ^number
        ),
        fn
          {field, nil}, query -> where(query, [a], is_nil(field(a, ^field)))
          {field, value}, query -> where(query, [a], field(a, ^field) == ^value)
        end
      )

    case Repo.delete_all(query) do
      {1, _} -> :ok
      _ -> {:error, :attempt_used}
    end
  end

  defp hash(state), do: :crypto.hash(:sha256, state)

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

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
