defmodule RengaWeb.AgentSocketTest do
  # Opens real WebSocket handshakes against the test server, so the
  # endpoint's transport options are covered, not just the socket callbacks.
  # Sockets are dispatched before the endpoint's sandbox plug, so the server
  # can only reach this test's data through a shared sandbox.
  use RengaWeb.ChannelCase, async: false

  import Renga.JobsFixtures

  alias Renga.Inventory

  setup do
    %{scope: scope} = job_organization_fixture()
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    %{token: token, installation_id: Ecto.UUID.generate()}
  end

  # Sends the upgrade request a Phoenix client makes and returns the status.
  defp handshake(headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port(), [:binary, active: false])

    request =
      [
        "GET /api/v1/agent/socket/websocket?vsn=2.0.0 HTTP/1.1",
        "host: 127.0.0.1",
        "connection: Upgrade",
        "upgrade: websocket",
        "sec-websocket-version: 13",
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ=="
        | headers
      ]
      |> Enum.join("\r\n")

    :ok = :gen_tcp.send(socket, request <> "\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    [status_line | _rest] = String.split(response, "\r\n")
    [_version, status | _reason] = String.split(status_line, " ")
    {String.to_integer(status), response}
  end

  defp port, do: RengaWeb.Endpoint.config(:http)[:port]

  defp auth_protocol(token),
    do:
      "sec-websocket-protocol: phoenix, base64url.bearer.phx.#{Base.encode64(token, padding: false)}"

  test "upgrades with the key as the auth token and the installation header", context do
    assert {101, response} =
             handshake([
               auth_protocol(context.token),
               "x-renga-installation-id: #{context.installation_id}"
             ])

    # Only the plain subprotocol is echoed back; the token never is.
    assert response =~ ~r/sec-websocket-protocol: phoenix\r\n/i
  end

  test "refuses a socket without a valid key", context do
    header = "x-renga-installation-id: #{context.installation_id}"

    assert {403, _response} = handshake([header])
    assert {403, _response} = handshake([auth_protocol("renga_intake_unknown"), header])
  end

  test "refuses a socket without an installation ID", context do
    assert {403, _response} = handshake([auth_protocol(context.token)])
  end

  test "does not accept the key in the URL" do
    assert {status, _response} = handshake([])
    assert status == 403
  end
end
