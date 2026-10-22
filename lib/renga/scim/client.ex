defmodule Renga.Scim.Client do
  @moduledoc """
  Who is making a SCIM change: the connection its token authenticated, the
  token, and the request ID. Every directory change is recorded with all
  three (RFD 16, "Audit").
  """

  @enforce_keys [:connection, :token_id]
  defstruct [:connection, :token_id, :request_id]

  @doc "What Activity records about the client behind a change."
  def cause(%__MODULE__{} = client) do
    %{
      "connection_id" => client.connection.id,
      "token_id" => client.token_id,
      "request_id" => client.request_id
    }
  end
end
