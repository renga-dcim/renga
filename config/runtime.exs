import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/renga start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :renga, RengaWeb.Endpoint, server: true
end

# Local sign-in policy (RFD 15): REGISTRATION=open|closed and
# LOCAL_SIGN_IN=enabled|disabled. Anything else stops the boot rather than
# guessing.
for {variable, key, values} <- [
      {"REGISTRATION", :registration, ~w(open closed)},
      {"LOCAL_SIGN_IN", :local_sign_in, ~w(enabled disabled)}
    ],
    value = System.get_env(variable) do
  unless value in values do
    raise "#{variable} must be one of #{Enum.join(values, ", ")}, got: #{inspect(value)}"
  end

  config :renga, key, String.to_atom(value)
end

# Destinations an organization's identity provider may reach although they
# are not public addresses, such as an internal enterprise provider (RFD 15):
# exact host names and address ranges, comma-separated. An entry that can't
# be read stops the boot.
if allow = System.get_env("ORGANIZATION_PROVIDER_ALLOW") do
  config :renga,
         :organization_provider_allow,
         Renga.Accounts.OIDC.Destinations.parse_allowlist(allow)
end

# An optional, non-secret name for this deployment, such as `eu1`. Intake
# keys issued while it is set carry it so a resolver can find the deployment
# (RFD 23).
case System.get_env("DEPLOYMENT_ID") do
  nil ->
    :ok

  "" ->
    :ok

  deployment_id ->
    unless Renga.Deployment.valid_id?(deployment_id) do
      raise """
      environment variable DEPLOYMENT_ID is invalid.
      Use at most 16 lowercase letters, digits, and hyphens, starting and
      ending with a letter or digit, such as eu1.
      """
    end

    config :renga, :deployment_id, deployment_id
end

# Deployment-wide limit defaults (RFD 21), such as LIMIT_JOB_CREATION_RATE.
# `renga-admin limits set` overrides them for one organization.
limit_defaults =
  for {name, %{env: env}} <- Renga.Limits.definitions(),
      value = System.get_env(env),
      value not in [nil, ""] do
    case Integer.parse(value) do
      {integer, ""} ->
        if Renga.Limits.valid_value?(integer),
          do: {name, integer},
          else: raise("environment variable #{env} must be from 0 to #{Renga.Limits.max_value()}")

      _other ->
        raise "environment variable #{env} must be a whole number from 0 to #{Renga.Limits.max_value()}"
    end
  end

if limit_defaults != [], do: config(:renga, Renga.Limits, limit_defaults)

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Managed PostgreSQL services require TLS. Verify the server certificate
  # against the OS trust store and the URL's host name, so enabling TLS also
  # protects against an impersonated database rather than only encrypting.
  database_ssl =
    if System.get_env("DATABASE_SSL") in ~w(true 1) do
      database_uri = URI.parse(database_url)

      conflicting_ssl? =
        database_uri.query
        |> then(&(&1 || ""))
        |> URI.query_decoder()
        |> Enum.any?(fn
          {"ssl", "true"} -> false
          {"ssl", _value} -> true
          _other -> false
        end)

      if conflicting_ssl? do
        raise "DATABASE_SSL=true cannot be combined with a DATABASE_URL ssl option other than ssl=true"
      end

      database_host = database_uri |> Map.fetch!(:host) |> String.to_charlist()

      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: database_host,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    else
      false
    end

  # Every application connection gets a baseline statement timeout, so a
  # standalone read is bounded as well as a transaction (RFD 21). Approved
  # background work may raise it per transaction with
  # Renga.Repo.with_statement_timeout/2, up to the background timeout.
  #
  # Both are whole milliseconds. A malformed, zero, or out-of-range value
  # stops the boot rather than silently disabling the bound, as does a
  # background timeout shorter than the baseline.
  statement_timeout_ms = fn variable, default ->
    value = System.get_env(variable) || default

    case Integer.parse(value) do
      # PostgreSQL's statement_timeout tops out at 2^31 - 1 milliseconds.
      {timeout_ms, ""} when timeout_ms in 1..2_147_483_647 ->
        timeout_ms

      _other ->
        raise "#{variable} must be a whole number of milliseconds from 1 to 2147483647, got: #{inspect(value)}"
    end
  end

  statement_timeout = statement_timeout_ms.("DATABASE_STATEMENT_TIMEOUT", "30000")

  background_statement_timeout =
    statement_timeout_ms.("DATABASE_BACKGROUND_STATEMENT_TIMEOUT", "300000")

  if background_statement_timeout < statement_timeout do
    raise "DATABASE_BACKGROUND_STATEMENT_TIMEOUT (#{background_statement_timeout}) must be at least DATABASE_STATEMENT_TIMEOUT (#{statement_timeout})"
  end

  config :renga, :background_statement_timeout_ms, background_statement_timeout

  config :renga, Renga.Repo,
    ssl: database_ssl,
    url: database_url,
    parameters: [statement_timeout: "#{statement_timeout}ms"],
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Agents send their intake keys to this host once it answers their home
  # request (RFD 23), so a placeholder would hand those keys to a stranger.
  host =
    case String.trim(System.get_env("PHX_HOST") || "") do
      "" ->
        raise """
        environment variable PHX_HOST is missing.
        Set it to the host name people and agents reach this deployment at.
        """

      host ->
        host
    end

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :renga, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :renga, :webauthn, origin: "https://#{host}"

  # Keys for secrets Renga stores and reads back, such as authenticator app
  # secrets and queued operator invitation links: a comma-separated list of
  # id:base64-key pairs, the first of which encrypts. Generate a key with
  # `openssl rand -base64 32`. To rotate, keep old keys until pending
  # invitation emails are delivered, run bin/reencrypt-secrets, then drop the
  # old key. Without a key, Renga runs but cannot add an authenticator app or
  # queue an operator invitation email.
  config :renga, Renga.Vault, keys: System.get_env("ENCRYPTION_KEYS")

  # The operator API listens on its own port, only when one is configured,
  # and only over HTTPS (RFD 22). The port may be public; set
  # OPERATOR_CLIENT_CA_FILE to also require a client certificate from that
  # authority.
  if operator_port = System.get_env("OPERATOR_PORT") do
    operator_setting = fn name ->
      System.get_env(name) ||
        raise "environment variable #{name} is required when OPERATOR_PORT is set"
    end

    operator_ip =
      case System.get_env("OPERATOR_IP") do
        nil ->
          {0, 0, 0, 0, 0, 0, 0, 0}

        address ->
          case :inet.parse_address(String.to_charlist(address)) do
            {:ok, ip} -> ip
            {:error, _reason} -> raise "environment variable OPERATOR_IP is not an IP address"
          end
      end

    operator_port =
      case Integer.parse(operator_port) do
        {number, ""} when number in 1..65_535 and number != port ->
          number

        _other ->
          raise "environment variable OPERATOR_PORT must be a port number other than PORT's"
      end

    client_crl_file = System.get_env("OPERATOR_CLIENT_CRL_FILE")
    client_ca_file = System.get_env("OPERATOR_CLIENT_CA_FILE")

    if client_crl_file && !client_ca_file do
      raise "OPERATOR_CLIENT_CRL_FILE requires OPERATOR_CLIENT_CA_FILE"
    end

    config :renga, :operator_client_crl_file, client_crl_file

    config :renga, RengaWeb.OperatorEndpoint,
      url: [host: host, port: operator_port, scheme: "https"],
      https:
        RengaWeb.OperatorListener.https_options(%{
          ip: operator_ip,
          port: operator_port,
          certfile: operator_setting.("OPERATOR_TLS_CERTFILE"),
          keyfile: operator_setting.("OPERATOR_TLS_KEYFILE"),
          client_ca_file: client_ca_file,
          client_crl_file: client_crl_file
        }),
      server: System.get_env("PHX_SERVER") != nil
  end

  config :renga, RengaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :renga, RengaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :renga, RengaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :renga, Renga.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
