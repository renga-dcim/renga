defmodule Renga.Accounts.OIDC.Discovery do
  @moduledoc """
  Caches each issuer's discovery document and signing keys (RFD 15). An
  entry lives as long as the provider's cache headers allow, between one
  minute and one hour, and the keys reload early when a token names a key ID
  Renga has not seen, so a provider can rotate keys without a restart.

  Entries are kept per issuer and policy (`:deployment` or `:organization`,
  see `Renga.Accounts.OIDC.HTTP`), so a document loaded for an operator's
  provider is never reused for an organization's, whose endpoints must pass
  the stricter destination check.

  Requests run in the caller's process; this server only owns the table.
  """

  use GenServer

  alias Renga.Accounts.OIDC.HTTP

  @table __MODULE__
  @min_ttl :timer.minutes(1)
  @max_ttl :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The issuer's configuration and signing keys, loading them when not cached."
  def fetch(issuer, policy \\ :deployment) when is_binary(issuer) do
    now = System.monotonic_time(:millisecond)
    key = {issuer, policy}

    case :ets.lookup(@table, key) do
      [{^key, configuration, jwks, expires_at}] when expires_at > now ->
        {:ok, configuration, jwks}

      _missing_or_expired ->
        load(issuer, policy)
    end
  end

  @doc "Reloads the issuer's signing keys, for a token signed with a key not seen before."
  def refresh_jwks(issuer, policy \\ :deployment) do
    key = {issuer, policy}

    with [{^key, configuration, _jwks, expires_at}] <- :ets.lookup(@table, key),
         {:ok, {jwks, _expiry}} <- load_jwks(configuration, policy) do
      :ets.insert(@table, {key, configuration, jwks, expires_at})
      {:ok, jwks}
    else
      [] -> {:error, :not_loaded}
      {:error, _reason} = error -> error
    end
  end

  @doc "Forgets an issuer, so the next sign-in loads it again."
  def evict(issuer) do
    :ets.delete(@table, {issuer, :deployment})
    :ets.delete(@table, {issuer, :organization})
  end

  defp load(issuer, policy) do
    # oidcc checks only the issuer's own scheme, so the endpoints the
    # document names are checked below: each must be https, or plain HTTP to
    # this machine, for development against a local identity provider.
    opts = %{
      request_opts: HTTP.request_opts(policy),
      quirks: %{allow_unsafe_http: policy == :deployment and local_http?(issuer)}
    }

    with {:ok, {configuration, configuration_ttl}} <-
           Oidcc.ProviderConfiguration.load_configuration(issuer, opts),
         :ok <- check_configuration(configuration, policy),
         {:ok, {jwks, jwks_ttl}} <- load_jwks(configuration, policy) do
      ttl = configuration_ttl |> min(jwks_ttl) |> max(@min_ttl) |> min(@max_ttl)

      :ets.insert(
        @table,
        {{issuer, policy}, configuration, jwks, System.monotonic_time(:millisecond) + ttl}
      )

      {:ok, configuration, jwks}
    end
  end

  # The endpoints sign-in sends the browser, the client secret, and the
  # PKCE verifier to, and where the signing keys come from. PKCE must be
  # S256: a provider that offers only `plain` would see the verifier itself.
  defp check_configuration(configuration, policy) do
    endpoints = [
      configuration.authorization_endpoint,
      configuration.token_endpoint,
      configuration.jwks_uri
    ]

    cond do
      not Enum.all?(endpoints, &HTTP.allowed_url?(&1, policy)) -> {:error, :insecure_endpoint}
      not s256?(configuration.code_challenge_methods_supported) -> {:error, :no_s256_pkce}
      true -> :ok
    end
  end

  defp s256?(methods) when is_list(methods), do: "S256" in methods
  defp s256?(_undefined), do: true

  defp local_http?(issuer) do
    match?(
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"],
      URI.parse(issuer)
    )
  end

  defp load_jwks(%Oidcc.ProviderConfiguration{jwks_uri: :undefined}, _policy),
    do: {:error, :no_jwks_uri}

  defp load_jwks(%Oidcc.ProviderConfiguration{jwks_uri: uri}, policy),
    do: Oidcc.ProviderConfiguration.load_jwks(uri, %{request_opts: HTTP.request_opts(policy)})
end
