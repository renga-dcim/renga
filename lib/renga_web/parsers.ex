defmodule RengaWeb.Parsers do
  @moduledoc """
  Parses request bodies. SCIM requests (RFD 16, "Endpoints") get their own,
  smaller bound and only the JSON parser, which also reads
  `application/scim+json`; an oversized or malformed SCIM body is answered
  with a SCIM error instead of the app's error page. Every other request is
  parsed as before.
  """

  @behaviour Plug

  alias RengaWeb.Scim.Response

  @default Plug.Parsers.init(
             parsers: [:urlencoded, :multipart, :json],
             pass: ["*/*"],
             json_decoder: Phoenix.json_library()
           )

  @scim_max_bytes 1_000_000

  @scim Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Phoenix.json_library(),
          length: @scim_max_bytes
        )

  @doc "The largest SCIM request body Renga reads, in bytes."
  def scim_max_bytes, do: @scim_max_bytes

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if scim_path?(conn.path_info),
      do: parse_scim(conn),
      else: Plug.Parsers.call(conn, @default)
  end

  # The router percent-decodes path segments before matching, so
  # /%73cim/v2/... reaches the SCIM routes too and must get the SCIM bound.
  defp scim_path?(["scim" | _rest]), do: true

  defp scim_path?([segment | _rest]) do
    URI.decode(segment) == "scim"
  rescue
    # The router refuses a malformed segment itself.
    ArgumentError -> false
  end

  defp scim_path?([]), do: false

  defp parse_scim(conn) do
    Plug.Parsers.call(conn, @scim)
  rescue
    Plug.Parsers.RequestTooLargeError ->
      conn
      |> Response.error(413, "The request body is larger than #{@scim_max_bytes} bytes")
      |> Plug.Conn.halt()

    _error in [Plug.Parsers.ParseError, Plug.Parsers.BadEncodingError] ->
      conn
      |> Response.error(400, "The request body is not valid JSON", "invalidSyntax")
      |> Plug.Conn.halt()
  end
end
