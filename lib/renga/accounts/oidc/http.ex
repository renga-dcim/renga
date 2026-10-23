defmodule Renga.Accounts.OIDC.HTTP do
  @moduledoc """
  The HTTP transport for `oidcc`, over Req (RFD 15, "Sign-in flow").

  Every request `oidcc` makes for Renga goes through here: discovery, signing
  keys, and the token exchange. Each goes only to an https URL, or over plain
  HTTP to this machine. Redirects are not followed, so a provider
  cannot send Renga somewhere its configuration does not name.

  A request carries its provider's policy. Deployment providers
  (`:deployment`) are configured by the operator, who is trusted with the
  destinations they name, private addresses included. An organization's
  provider (`:organization`) is chosen by its owners, so its requests go only
  over https to the public addresses `Renga.Accounts.OIDC.Destinations`
  allows, and connect to the address that was checked. Tests route requests
  to a `Req.Test` stub with `config :renga, :oidc_req_options`.
  """

  alias Renga.Accounts.OIDC.Destinations
  alias Renga.Accounts.OIDC.PinnedTransport

  @behaviour :oidcc_http_adapter

  @doc "The `request_opts` that make `oidcc` use this adapter under `policy`."
  def request_opts(policy \\ :deployment) when policy in [:deployment, :organization],
    do: %{http_adapter: {__MODULE__, %{policy: policy}}, timeout: :timer.seconds(10)}

  @doc """
  Whether Renga sends anything to `url`: an absolute https URL, or plain HTTP
  only to this machine's loopback address. Neither may carry credentials or
  a fragment.
  """
  def allowed_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host, userinfo: nil, fragment: nil}
      when host in ["localhost", "127.0.0.1", "::1"] ->
        true

      _other ->
        false
    end
  end

  def allowed_url?(_url), do: false

  @doc """
  Whether Renga sends anything to `url` under `policy`. An organization's
  provider gets no plain-HTTP exception; its destination is checked again
  when the request is made.
  """
  def allowed_url?(url, :deployment), do: allowed_url?(url)

  def allowed_url?(url, :organization),
    do: allowed_url?(url) and match?(%URI{scheme: "https"}, URI.parse(url))

  @impl true
  def request(method, request, http_options, _request_options, config) do
    {url, headers, body} = split(request)
    url = to_string(url)
    headers = Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
    policy = Map.get(config, :policy, :deployment)

    with true <- allowed_url?(url, policy) || {:error, :insecure_endpoint},
         {:ok, target} <- target(url, headers, policy) do
      send_request(method, target, body, http_options)
    end
  end

  defp target(url, headers, :deployment), do: {:ok, %{url: url, headers: headers, tls: nil}}

  # Connects to the address the policy checked rather than resolving the
  # name again, keeping the name for the Host header and for TLS (SNI and
  # certificate verification). `URI.to_string/1` brackets an IPv6 host
  # itself, so the host stays bare here.
  defp target(url, headers, :organization) do
    with {:ok, address} <- Destinations.check(url) do
      %URI{host: host} = uri = URI.parse(url)

      {:ok,
       %{
         url: URI.to_string(%{uri | host: to_string(:inet.ntoa(address))}),
         headers: [{"host", host_header(uri)} | Enum.reject(headers, &(elem(&1, 0) == "host"))],
         tls: host
       }}
    end
  end

  defp host_header(%URI{host: host, port: port}) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == 443, do: host, else: "#{host}:#{port}"
  end

  defp send_request(method, target, body, http_options) do
    options =
      [
        method: method,
        url: target.url,
        headers: target.headers,
        body: body,
        decode_body: false,
        redirect: false,
        retry: false,
        receive_timeout: Keyword.get(http_options, :timeout, :timer.seconds(10))
      ]
      |> Keyword.merge(pinned(target))
      |> Keyword.merge(Application.get_env(:renga, :oidc_req_options, []))

    request =
      options
      |> Req.new()
      |> Req.Request.put_private(:renga_tls_hostname, target.tls)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, headers: response_headers, body: response_body}} ->
        {:ok, {{~c"HTTP/1.1", status, ~c""}, charlist_headers(response_headers), response_body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # An organization's request connects through `PinnedTransport`, which
  # opens no Finch pool for the host names its owners choose.
  defp pinned(%{tls: nil}), do: []
  defp pinned(_target), do: [adapter: &PinnedTransport.run/1]

  defp split({url, headers}), do: {url, headers, nil}

  defp split({url, headers, content_type, body}),
    do: {url, [{~c"content-type", content_type} | headers], IO.iodata_to_binary(body)}

  # httpc's shape: lowercase charlist names and values.
  defp charlist_headers(headers) do
    for {name, values} <- headers, value <- List.wrap(values) do
      {String.to_charlist(String.downcase(name)), String.to_charlist(value)}
    end
  end
end
