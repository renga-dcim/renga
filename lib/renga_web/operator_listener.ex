defmodule RengaWeb.OperatorListener do
  @moduledoc """
  Builds the operator listener's HTTPS options from the deployment's settings
  (RFD 22, "Listener").

  With a client certificate authority configured, the TLS handshake completes
  only for a client presenting a certificate issued by it, so a request
  without one is refused before its token is read. Client certificates are
  checked against that authority alone, and its revocation list when one is
  given, never against the public web PKI.
  """

  @doc """
  Returns Bandit `https:` options.

  Takes `:port`, `:ip`, `:certfile`, and `:keyfile`, and optionally
  `:client_ca_file` to require client certificates and `:client_crl_file`
  with that authority's revocation list.

  Bandit accepts only its own keys at the top level, so the client
  certificate checks go to the TLS transport through
  `:thousand_island_options`.
  """
  def https_options(settings) do
    [
      ip: Map.fetch!(settings, :ip),
      port: Map.fetch!(settings, :port),
      cipher_suite: :strong,
      certfile: Map.fetch!(settings, :certfile),
      keyfile: Map.fetch!(settings, :keyfile)
    ] ++ transport_options(client_certificate_options(settings))
  end

  defp transport_options([]), do: []
  defp transport_options(options), do: [thousand_island_options: [transport_options: options]]

  defp client_certificate_options(%{client_ca_file: ca_file} = settings)
       when is_binary(ca_file) do
    [
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      cacertfile: ca_file
    ] ++ revocation_options(settings)
  end

  defp client_certificate_options(_settings), do: []

  # `true` checks every certificate in the client's chain, so a revoked
  # intermediate authority is refused too; `:peer` would check only the leaf.
  # The file must therefore hold a current list from every authority in the
  # chain, and a chain without one fails the handshake.
  defp revocation_options(%{client_crl_file: crl_file}) when is_binary(crl_file) do
    [crl_check: true, crl_cache: {:ssl_crl_cache, {:internal, []}}]
  end

  defp revocation_options(_settings), do: []

  @doc """
  Loads the configured certificate revocation lists, a PEM bundle, into the
  TLS stack's cache. Called once at startup; a changed file takes effect on
  restart.

  The TLS stack would accept a file holding no PEM list, such as a DER one,
  and then refuse every client, so such a file stops the boot instead.
  """
  def load_revocation_list do
    case Application.get_env(:renga, :operator_client_crl_file) do
      nil ->
        :ok

      path ->
        crls = for {:CertificateList, _der, _} <- :public_key.pem_decode(File.read!(path)), do: 1

        if crls == [] do
          raise "OPERATOR_CLIENT_CRL_FILE #{path} holds no PEM certificate revocation list"
        end

        {:ok, _apps} = Application.ensure_all_started(:ssl)
        :ok = :ssl_crl_cache.insert({:file, String.to_charlist(path)})
    end
  end
end
