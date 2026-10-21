defmodule RengaWeb.OperatorListenerTest do
  # Starts real HTTPS listeners, which reach the database from their own
  # processes through the shared sandbox.
  use RengaWeb.OperatorCase, async: false

  alias RengaWeb.OperatorListener

  @moduletag :tmp_dir

  # A throwaway certificate authority with a server certificate, a client
  # certificate, and a revoked client certificate listed in its CRL.
  @pki_script ~S"""
  set -e
  cd "$1"
  touch index.txt; echo 01 > serial; echo 01 > crlnumber
  cat > ca.cnf <<CNF
  [ca]
  default_ca = ca_default
  [ca_default]
  dir = .
  database = index.txt
  serial = serial
  crlnumber = crlnumber
  new_certs_dir = .
  default_md = sha256
  default_days = 1
  default_crl_days = 1
  policy = policy_any
  [policy_any]
  commonName = supplied
  CNF
  key="-newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes"
  openssl req -x509 $key -keyout ca.key -out ca.pem -days 1 -subj /CN=operator-test-ca
  issue() {
    openssl req $key -keyout $1.key -out $1.csr -subj /CN=$2
    printf "$3" > $1.ext
    openssl x509 -req -in $1.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $1.pem -days 1 -extfile $1.ext
  }
  issue server localhost "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n"
  issue client control-plane "extendedKeyUsage=clientAuth\n"
  issue revoked revoked-client "extendedKeyUsage=clientAuth\n"
  openssl ca -config ca.cnf -keyfile ca.key -cert ca.pem -revoke revoked.pem -batch
  openssl ca -config ca.cnf -keyfile ca.key -cert ca.pem -gencrl -out ca.crl -batch
  """

  setup %{tmp_dir: dir} do
    {_output, 0} =
      System.cmd("sh", ["-c", String.replace(@pki_script, "\n  ", "\n"), "sh", dir],
        stderr_to_stdout: true
      )

    {_token, plaintext} = operator_token_fixture()
    %{pki: dir, plaintext: plaintext}
  end

  defp start_listener(settings) do
    https = OperatorListener.https_options(Map.merge(%{ip: {127, 0, 0, 1}, port: 0}, settings))
    {transport_options, bandit_options} = Keyword.split(https, [:ip, :port])

    pid =
      start_supervised!(
        {Bandit,
         plug: RengaWeb.OperatorEndpoint,
         scheme: :https,
         ip: transport_options[:ip],
         port: 0,
         thousand_island_options: [
           transport_options: Keyword.drop(bandit_options, [:cipher_suite])
         ],
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp request(port, pki, plaintext, client \\ nil) do
    client_options =
      if client,
        do: [certfile: Path.join(pki, "#{client}.pem"), keyfile: Path.join(pki, "#{client}.key")],
        else: []

    Req.get("https://localhost:#{port}/operator/v1/deployment",
      headers: [authorization: "Bearer " <> plaintext],
      retry: false,
      connect_options: [
        transport_opts: [cacertfile: Path.join(pki, "ca.pem")] ++ client_options
      ]
    )
  end

  defp server_files(pki),
    do: %{certfile: Path.join(pki, "server.pem"), keyfile: Path.join(pki, "server.key")}

  test "serves the API over HTTPS without client certificates by default", %{
    pki: pki,
    plaintext: plaintext
  } do
    port = start_listener(server_files(pki))

    assert {:ok, %{status: 200}} = request(port, pki, plaintext)
  end

  test "with mutual TLS, completes the handshake only for a certificate from the configured authority",
       %{pki: pki, plaintext: plaintext} do
    port = start_listener(Map.put(server_files(pki), :client_ca_file, Path.join(pki, "ca.pem")))

    assert {:ok, %{status: 200}} = request(port, pki, plaintext, "client")
    # Without a revocation list, a revoked certificate still verifies.
    assert {:ok, %{status: 200}} = request(port, pki, plaintext, "revoked")

    # Refused during the handshake, so the token is never read.
    assert {:error, %Req.TransportError{}} = request(port, pki, plaintext)
  end

  test "with a revocation list, refuses a revoked client certificate", %{
    pki: pki,
    plaintext: plaintext
  } do
    Application.put_env(:renga, :operator_client_crl_file, Path.join(pki, "ca.crl"))
    on_exit(fn -> Application.delete_env(:renga, :operator_client_crl_file) end)
    :ok = OperatorListener.load_revocation_list()

    port =
      start_listener(
        server_files(pki)
        |> Map.put(:client_ca_file, Path.join(pki, "ca.pem"))
        |> Map.put(:client_crl_file, Path.join(pki, "ca.crl"))
      )

    assert {:ok, %{status: 200}} = request(port, pki, plaintext, "client")
    assert {:error, %Req.TransportError{}} = request(port, pki, plaintext, "revoked")
  end

  describe "https_options/1" do
    test "never trusts the public web PKI for client certificates" do
      options =
        OperatorListener.https_options(%{
          ip: {0, 0, 0, 0},
          port: 4443,
          certfile: "server.pem",
          keyfile: "server.key",
          client_ca_file: "ca.pem"
        })

      assert options[:cacertfile] == "ca.pem"
      assert options[:verify] == :verify_peer
      assert options[:fail_if_no_peer_cert]
      refute Keyword.has_key?(options, :cacerts)
    end
  end
end
