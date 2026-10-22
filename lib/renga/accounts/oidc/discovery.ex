defmodule Renga.Accounts.OIDC.Discovery do
  @moduledoc """
  Caches each issuer's discovery document and signing keys (RFD 15). An
  entry lives as long as the provider's cache headers allow, between one
  minute and one hour, and the keys reload early when a token names a key ID
  Renga has not seen, so a provider can rotate keys without a restart.

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
  def fetch(issuer) when is_binary(issuer) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, issuer) do
      [{^issuer, configuration, jwks, expires_at}] when expires_at > now ->
        {:ok, configuration, jwks}

      _missing_or_expired ->
        load(issuer)
    end
  end

  @doc "Reloads the issuer's signing keys, for a token signed with a key not seen before."
  def refresh_jwks(issuer) do
    with [{^issuer, configuration, _jwks, expires_at}] <- :ets.lookup(@table, issuer),
         {:ok, {jwks, _expiry}} <- load_jwks(configuration) do
      :ets.insert(@table, {issuer, configuration, jwks, expires_at})
      {:ok, jwks}
    else
      [] -> {:error, :not_loaded}
      {:error, _reason} = error -> error
    end
  end

  @doc "Forgets an issuer, so the next sign-in loads it again."
  def evict(issuer), do: :ets.delete(@table, issuer)

  defp load(issuer) do
    # oidcc checks only the issuer's own scheme, so the endpoints the
    # document names are checked below: each must be https, or plain HTTP to
    # this machine, for development against a local identity provider.
    opts = %{
      request_opts: HTTP.request_opts(),
      quirks: %{allow_unsafe_http: local_http?(issuer)}
    }

    with {:ok, {configuration, configuration_ttl}} <-
           Oidcc.ProviderConfiguration.load_configuration(issuer, opts),
         :ok <- check_configuration(configuration),
         {:ok, {jwks, jwks_ttl}} <- load_jwks(configuration) do
      ttl = configuration_ttl |> min(jwks_ttl) |> max(@min_ttl) |> min(@max_ttl)

      :ets.insert(
        @table,
        {issuer, configuration, jwks, System.monotonic_time(:millisecond) + ttl}
      )

      {:ok, configuration, jwks}
    end
  end

  # The endpoints sign-in sends the browser, the client secret, and the
  # PKCE verifier to, and where the signing keys come from. PKCE must be
  # S256: a provider that offers only `plain` would see the verifier itself.
  defp check_configuration(configuration) do
    endpoints = [
      configuration.authorization_endpoint,
      configuration.token_endpoint,
      configuration.jwks_uri
    ]

    cond do
      not Enum.all?(endpoints, &HTTP.allowed_url?/1) -> {:error, :insecure_endpoint}
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

  defp load_jwks(%Oidcc.ProviderConfiguration{jwks_uri: :undefined}), do: {:error, :no_jwks_uri}

  defp load_jwks(%Oidcc.ProviderConfiguration{jwks_uri: uri}),
    do: Oidcc.ProviderConfiguration.load_jwks(uri, %{request_opts: HTTP.request_opts()})
end
