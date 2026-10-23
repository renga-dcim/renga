defmodule Renga.Accounts.OIDC.PinnedTransport do
  @moduledoc """
  The Req adapter for an organization provider's requests (RFD 15,
  "Organization providers"). Each request opens one Mint connection to the
  address in its URL, which `Renga.Accounts.OIDC.HTTP` set to the address
  the destination policy checked, and closes it when the response ends.
  The provider's host name, from the request's `:renga_tls_hostname`
  private, is used for SNI and certificate verification.

  Req's `connect_options: [hostname: ...]` would do the same through Finch,
  but it starts a pool, with its own registered names, for every distinct
  set of connect options. An organization's owners choose the host names
  their provider's documents point to, so that would let them create pools
  and atoms without bound. Nothing here outlives the request.
  """

  # Discovery documents, signing keys, and token responses are small.
  @max_body 1_048_576

  @doc "Runs `request` as a `Req` adapter."
  def run(%Req.Request{url: %URI{} = uri} = request) do
    hostname = Req.Request.get_private(request, :renga_tls_hostname)
    deadline = System.monotonic_time(:millisecond) + (request.options[:receive_timeout] || 10_000)

    with {:ok, address} <- :inet.parse_strict_address(String.to_charlist(uri.host)),
         {:ok, conn} <-
           Mint.HTTP.connect(scheme(uri), address, uri.port,
             hostname: hostname,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: remaining(deadline)]
           ) do
      # The connection is closed however the exchange ends.
      {conn, result} =
        try do
          case exchange(conn, request, uri, deadline) do
            {:ok, conn, response} -> {conn, {request, Req.Response.new(response)}}
            {:error, conn, reason} -> {conn, {request, exception(reason)}}
          end
        rescue
          error ->
            Mint.HTTP.close(conn)
            reraise error, __STACKTRACE__
        end

      Mint.HTTP.close(conn)
      result
    else
      {:error, reason} -> {request, exception(reason)}
    end
  end

  defp exchange(conn, request, uri, deadline) do
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}
    method = request.method |> to_string() |> String.upcase()

    case Mint.HTTP.request(conn, method, path(uri), headers, request.body) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, %{status: nil, headers: [], body: ""}, deadline)

      {:error, conn, reason} ->
        {:error, conn, reason}
    end
  end

  # A receive with no time left would only poll, and a provider that keeps
  # data buffered, such as endless informational responses, could hold the
  # request past its deadline; it ends there instead.
  defp receive_response(conn, ref, response, deadline) do
    case remaining(deadline) do
      0 -> {:error, conn, :timeout}
      timeout -> receive_parts(conn, ref, response, deadline, timeout)
    end
  end

  defp receive_parts(conn, ref, response, deadline, timeout) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, parts} ->
        case collect(parts, ref, response) do
          {_state, response} when byte_size(response.body) > @max_body ->
            {:error, conn, :response_too_large}

          {:done, response} ->
            {:ok, conn, response}

          {:more, response} ->
            receive_response(conn, ref, response, deadline)
        end

      {:error, conn, reason, _parts} ->
        {:error, conn, reason}
    end
  end

  defp collect([], _ref, response), do: {:more, response}
  defp collect([{:done, ref} | _rest], ref, response), do: {:done, response}

  # An informational (1xx) response comes before the final one; its headers
  # are not the response's.
  defp collect([{:status, ref, status} | rest], ref, response),
    do: collect(rest, ref, %{response | status: status, headers: []})

  defp collect([{:headers, ref, headers} | rest], ref, response),
    do: collect(rest, ref, %{response | headers: response.headers ++ headers})

  defp collect([{:data, ref, data} | rest], ref, response),
    do: collect(rest, ref, %{response | body: response.body <> data})

  defp collect([_other | rest], ref, response), do: collect(rest, ref, response)

  defp scheme(%URI{scheme: "https"}), do: :https
  defp scheme(%URI{scheme: "http"}), do: :http

  defp path(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query, do: path <> "?" <> query, else: path
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp exception(%{__exception__: true} = exception), do: exception

  defp exception(reason),
    do: RuntimeError.exception("provider request failed: #{inspect(reason)}")
end
