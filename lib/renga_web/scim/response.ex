defmodule RengaWeb.Scim.Response do
  @moduledoc """
  Sends SCIM responses (RFC 7644, section 3.12): `application/scim+json`
  bodies, and errors in the SCIM error schema.
  """

  import Plug.Conn

  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  @doc "Sends `body` as SCIM JSON with `status`."
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/scim+json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end

  @doc """
  Sends a SCIM error. `scim_type` is one of RFC 7644's detail error keywords,
  such as `"uniqueness"` or `"invalidValue"`, and only accompanies a `400`
  or `409`.
  """
  def error(conn, status, detail, scim_type \\ nil) do
    body =
      %{"schemas" => [@error_schema], "status" => Integer.to_string(status), "detail" => detail}
      |> then(&if(scim_type, do: Map.put(&1, "scimType", scim_type), else: &1))

    json(conn, status, body)
  end

end
