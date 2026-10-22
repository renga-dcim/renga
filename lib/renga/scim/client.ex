defmodule Renga.Scim.Client do
  @moduledoc """
  Who is making a SCIM change: the connection its token authenticated, the
  token, and the request ID. Every directory change is recorded with all
  three (RFD 16, "Audit").
  """

  @enforce_keys [:connection, :token_id]
  defstruct [:connection, :token_id, :request_id]
end
