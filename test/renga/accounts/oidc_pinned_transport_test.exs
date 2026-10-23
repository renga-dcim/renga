defmodule Renga.Accounts.OIDC.PinnedTransportTest do
  use ExUnit.Case, async: true

  alias Renga.Accounts.OIDC.PinnedTransport

  # A one-shot HTTP/1.1 server on the IPv6 loopback that reports the request
  # it read and answers `response`.
  defp serve(response) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, :inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, active: false])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(parent, {:request, request})
      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end)

    port
  end

  defp request(port) do
    Req.new(
      url: "http://[::1]:#{port}/token?x=1",
      method: :get,
      headers: [{"host", "idp.example.com"}],
      receive_timeout: 5_000,
      retry: false
    )
    |> Req.Request.put_private(:renga_tls_hostname, "idp.example.com")
  end

  test "connects once to the address in the URL and keeps the provider's name" do
    port = serve("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
    pools = DynamicSupervisor.count_children(Req.FinchSupervisor)

    assert {_request, %Req.Response{status: 200, body: "ok"}} = PinnedTransport.run(request(port))
    assert_received {:request, "GET /token?x=1 HTTP/1.1\r\n" <> headers}
    assert headers =~ ~r/^host: idp\.example\.com\r$/m

    # No Finch pool is started for the host name.
    assert DynamicSupervisor.count_children(Req.FinchSupervisor) == pools
  end

  test "gives up at the deadline however much the provider keeps sending" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, :inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}, active: false])

    {:ok, port} = :inet.port(listen)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      flood = fn flood ->
        :gen_tcp.send(socket, "HTTP/1.1 103 Early Hints\r\nlink: x\r\n\r\n") == :ok and
          flood.(flood)
      end

      flood.(flood)
      send(parent, :closed)
    end)

    request = %{request(port) | options: Map.put(request(port).options, :receive_timeout, 300)}
    {elapsed, result} = :timer.tc(fn -> PinnedTransport.run(request) end, :millisecond)

    assert {_request, %RuntimeError{}} = result
    assert elapsed < 2_000
    # The connection is closed, so the provider's writes start failing.
    assert_receive :closed, 2_000
  end

  test "refuses a response larger than any provider document" do
    body = String.duplicate("a", 1_100_000)
    port = serve("HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body)

    assert {_request, %RuntimeError{}} = PinnedTransport.run(request(port))
  end
end
