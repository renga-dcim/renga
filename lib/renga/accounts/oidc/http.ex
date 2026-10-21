defmodule Renga.Accounts.OIDC.HTTP do
  @moduledoc """
  The HTTP transport for `oidcc`, over Req (RFD 15, "Sign-in flow").

  Every request `oidcc` makes for Renga goes through here: discovery, signing
  keys, and the token exchange. Redirects are not followed, so a provider
  cannot send Renga somewhere its configuration does not name; organization
  providers will add their destination policy here. Tests route requests to a
  `Req.Test` stub with `config :renga, :oidc_req_options`.
  """

  @behaviour :oidcc_http_adapter

  @doc "The `request_opts` that make `oidcc` use this adapter."
  def request_opts, do: %{http_adapter: {__MODULE__, %{}}, timeout: :timer.seconds(10)}

  @impl true
  def request(method, request, http_options, _request_options, _config) do
    {url, headers, body} = split(request)

    options =
      [
        method: method,
        url: to_string(url),
        headers: Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end),
        body: body,
        decode_body: false,
        redirect: false,
        retry: false,
        receive_timeout: Keyword.get(http_options, :timeout, :timer.seconds(10))
      ]
      |> Keyword.merge(Application.get_env(:renga, :oidc_req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status, headers: response_headers, body: response_body}} ->
        {:ok, {{~c"HTTP/1.1", status, ~c""}, charlist_headers(response_headers), response_body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

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
