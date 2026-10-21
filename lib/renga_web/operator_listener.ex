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
  """
  def https_options(settings) do
    [
      ip: Map.fetch!(settings, :ip),
      port: Map.fetch!(settings, :port),
      cipher_suite: :strong,
      certfile: Map.fetch!(settings, :certfile),
      keyfile: Map.fetch!(settings, :keyfile)
    ] ++ client_certificate_options(settings)
  end

  defp client_certificate_options(%{client_ca_file: ca_file} = settings)
       when is_binary(ca_file) do
    [
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      cacertfile: ca_file
    ] ++ revocation_options(settings)
  end

  defp client_certificate_options(_settings), do: []

  defp revocation_options(%{client_crl_file: crl_file}) when is_binary(crl_file) do
    [crl_check: :peer, crl_cache: {:ssl_crl_cache, {:internal, []}}]
  end

  defp revocation_options(_settings), do: []

  @doc """
  Loads the configured certificate revocation list into the TLS stack's
  cache. Called once at startup; a changed list takes effect on restart.
  """
  def load_revocation_list do
    case Application.get_env(:renga, :operator_client_crl_file) do
      nil ->
        :ok

      path ->
        {:ok, _apps} = Application.ensure_all_started(:ssl)
        :ok = :ssl_crl_cache.insert({:file, String.to_charlist(path)})
    end
  end
end
