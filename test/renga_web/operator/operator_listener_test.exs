defmodule RengaWeb.OperatorListenerTest do
  # Starts real HTTPS listeners, which reach the database from their own
  # processes through the shared sandbox.
  use RengaWeb.OperatorCase, async: false

  alias RengaWeb.OperatorListener

  @moduletag :tmp_dir

  # A throwaway root authority with a server certificate and client
  # certificates: a valid one, a revoked one, an expired one, and one from a
  # good and one from a revoked intermediate authority, whose chain files
  # carry the intermediate. A second, unrelated authority issues one more.
  # ca.crl bundles the root's list and both intermediates'.
  @pki_script ~S"""
  set -e
  cd "$1"
  key="-newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes"
  authority() {
    mkdir -p $1.db; touch $1.db/index.txt; echo 01 > $1.db/serial; echo 01 > $1.db/crlnumber
    cat > $1.cnf <<CNF
  [ca]
  default_ca = ca_default
  [ca_default]
  dir = $1.db
  database = $1.db/index.txt
  serial = $1.db/serial
  crlnumber = $1.db/crlnumber
  new_certs_dir = $1.db
  default_md = sha256
  default_days = 1
  default_crl_days = 1
  policy = policy_any
  copy_extensions = none
  [policy_any]
  commonName = supplied
  CNF
  }
  # sign AUTHORITY NAME CN EXTENSIONS [openssl ca options...]
  sign() {
    authority=$1; name=$2; cn=$3; printf "$4" > $name.ext; shift 4
    openssl req $key -keyout $name.key -out $name.csr -subj /CN=$cn
    openssl ca -config $authority.cnf -keyfile $authority.key -cert $authority.pem \
      -in $name.csr -out $name.pem -extfile $name.ext -batch -notext "$@"
  }
  leaf_client="extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n"
  sub_ca="basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
  authority ca
  openssl req -x509 $key -keyout ca.key -out ca.pem -days 1 -subj /CN=operator-test-ca \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
  sign ca server localhost "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n"
  sign ca client control-plane "$leaf_client"
  sign ca revoked revoked-client "$leaf_client"
  sign ca expired expired-client "$leaf_client" -startdate 20200101000000Z -enddate 20200102000000Z
  for intermediate in good-intermediate revoked-intermediate; do
    sign ca $intermediate $intermediate "$sub_ca"
    authority $intermediate
    sign $intermediate $intermediate-client $intermediate-client "$leaf_client"
    cat $intermediate-client.pem $intermediate.pem > $intermediate-client-chain.pem
    openssl ca -config $intermediate.cnf -keyfile $intermediate.key -cert $intermediate.pem \
      -gencrl -out $intermediate.crl -batch
  done
  openssl ca -config ca.cnf -keyfile ca.key -cert ca.pem -revoke revoked.pem -batch
  openssl ca -config ca.cnf -keyfile ca.key -cert ca.pem -revoke revoked-intermediate.pem -batch
  openssl ca -config ca.cnf -keyfile ca.key -cert ca.pem -gencrl -out root.crl -batch
  cat root.crl good-intermediate.crl revoked-intermediate.crl > ca.crl
  openssl crl -in ca.crl -outform DER -out ca.der
  openssl req -x509 $key -keyout other-ca.key -out other-ca.pem -days 1 -subj /CN=other-ca
  authority other-ca
  sign other-ca stranger stranger-client "$leaf_client"
  """

  setup %{tmp_dir: dir} do
    {_output, 0} =
      System.cmd("sh", ["-c", String.replace(@pki_script, "\n  ", "\n"), "sh", dir],
        stderr_to_stdout: true
      )

    {_token, plaintext} = operator_token_fixture()
    %{pki: dir, plaintext: plaintext}
  end

  # Starts the listener the way the endpoint does in production, from the
  # same `https:` options.
  defp start_listener(settings) do
    https = OperatorListener.https_options(Map.merge(%{ip: {127, 0, 0, 1}, port: 0}, settings))

    [spec] =
      Bandit.PhoenixAdapter.child_specs(RengaWeb.OperatorEndpoint,
        otp_app: :renga,
        https: Keyword.put(https, :startup_log, false)
      )

    pid = start_supervised!(spec)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # `client` names a certificate and key in `pki`; a `{:chain, name}` client
  # presents its intermediate authority too.
  defp request(port, pki, plaintext, client \\ nil) do
    client_options =
      case client do
        nil ->
          []

        {:chain, name} ->
          [
            certfile: Path.join(pki, "#{name}-client-chain.pem"),
            keyfile: Path.join(pki, "#{name}-client.key")
          ]

        name ->
          [certfile: Path.join(pki, "#{name}.pem"), keyfile: Path.join(pki, "#{name}.key")]
      end

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
    assert {:ok, %{status: 200}} = request(port, pki, plaintext, {:chain, "good-intermediate"})
    # Without revocation lists, revoked certificates and authorities still verify.
    assert {:ok, %{status: 200}} = request(port, pki, plaintext, "revoked")
    assert {:ok, %{status: 200}} = request(port, pki, plaintext, {:chain, "revoked-intermediate"})

    # Refused during the handshake, so the token is never read: no
    # certificate, one from another authority, and an expired one.
    for client <- [nil, "stranger", "expired"] do
      assert {:error, %Req.TransportError{}} = request(port, pki, plaintext, client),
             inspect(client)
    end
  end

  test "with a revocation list, refuses a revoked client certificate", %{
    pki: pki,
    plaintext: plaintext
  } do
    crl_file = Path.join(pki, "ca.crl")
    Application.put_env(:renga, :operator_client_crl_file, crl_file)

    on_exit(fn ->
      Application.delete_env(:renga, :operator_client_crl_file)
      :ssl_crl_cache.delete({:file, String.to_charlist(crl_file)})
    end)

    :ok = OperatorListener.load_revocation_list()

    port =
      start_listener(
        server_files(pki)
        |> Map.put(:client_ca_file, Path.join(pki, "ca.pem"))
        |> Map.put(:client_crl_file, Path.join(pki, "ca.crl"))
      )

    assert {:ok, %{status: 200}} = request(port, pki, plaintext, "client")
    assert {:ok, %{status: 200}} = request(port, pki, plaintext, {:chain, "good-intermediate"})
    assert {:error, %Req.TransportError{}} = request(port, pki, plaintext, "revoked")
    # The client itself is not revoked, but the authority that issued it is.
    assert {:error, %Req.TransportError{}} =
             request(port, pki, plaintext, {:chain, "revoked-intermediate"})
  end

  test "refuses to boot with a revocation list file it cannot read as PEM", %{pki: pki} do
    Application.put_env(:renga, :operator_client_crl_file, Path.join(pki, "ca.der"))
    on_exit(fn -> Application.delete_env(:renga, :operator_client_crl_file) end)

    assert_raise RuntimeError, ~r/holds no PEM certificate revocation list/, fn ->
      OperatorListener.load_revocation_list()
    end
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

      transport = options[:thousand_island_options][:transport_options]
      assert transport[:cacertfile] == "ca.pem"
      assert transport[:verify] == :verify_peer
      assert transport[:fail_if_no_peer_cert]
      refute Keyword.has_key?(transport, :cacerts)
    end
  end
end
