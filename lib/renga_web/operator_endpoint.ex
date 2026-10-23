defmodule RengaWeb.OperatorEndpoint do
  @moduledoc """
  The operator API's own listener (RFD 22).

  The operator API is never served on the listener people and agents use. A
  whole listener can carry rules a path prefix on a shared port cannot, such
  as requiring a client certificate, a firewall rule, or a separate reverse
  proxy. The port may be public, so nothing here assumes a private network:
  every request still authenticates with an operator token.

  It has no sessions, cookies, sockets, or static files.
  """

  use Phoenix.Endpoint, otp_app: :renga

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :operator_endpoint]

  # Every request authenticates before anything else reads it, so while the
  # API is off every request gets the same 404, whatever its path, method,
  # or body.
  plug RengaWeb.OperatorAuth

  # Body-taking operations read and parse their payloads inside authenticated
  # controllers, so nothing between authentication and an operation can refuse
  # a request without the operation recording the attempt (RFD 22, "Audit").
  plug RengaWeb.OperatorRouter
end
