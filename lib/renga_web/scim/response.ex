defmodule RengaWeb.Scim.Response do
  @moduledoc """
  Sends SCIM responses (RFC 7644, section 3.12): `application/scim+json`
  bodies, and errors in the SCIM error schema.
  """

  import Plug.Conn

  alias Renga.Scim.Attributes
  alias RengaWeb.Scim.Schemas

  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"
  @patch_schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  @scim_types %{
    invalid_filter: "invalidFilter",
    invalid_path: "invalidPath",
    invalid_syntax: "invalidSyntax",
    invalid_value: "invalidValue",
    mutability: "mutability",
    no_target: "noTarget",
    too_many: "tooMany",
    uniqueness: "uniqueness"
  }

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

  @doc "The client a request's change is attributed to."
  def client(conn) do
    %Renga.Scim.Client{
      connection: conn.assigns.scim_connection,
      token_id: conn.assigns.scim_token.id,
      request_id: conn |> get_resp_header("x-request-id") |> List.first()
    }
  end

  @doc """
  Sends the error for a context's `{:error, reason}`: `:not_found`,
  `:forbidden` (the organization is no longer active), or a
  `{scim_type, detail}` pair.
  """
  def failure(conn, :not_found), do: error(conn, 404, "No such SCIM resource")
  def failure(conn, :forbidden), do: error(conn, 403, "The organization is not active")

  def failure(conn, {:uniqueness, detail}), do: error(conn, 409, detail, "uniqueness")

  def failure(conn, {scim_type, detail}) when is_map_key(@scim_types, scim_type),
    do: error(conn, 400, detail, Map.fetch!(@scim_types, scim_type))

  @doc """
  The page a list request asks for, as `{start_index, count}`. `startIndex`
  below 1 means 1 and `count` is capped at the maximum page size (RFC 7644,
  section 3.4.2.4).
  """
  def page(params) do
    with {:ok, start_index} <- integer(params["startIndex"], 1),
         {:ok, count} <- integer(params["count"], Schemas.max_results()) do
      {:ok, {max(start_index, 1), count |> max(0) |> min(Schemas.max_results())}}
    end
  end

  defp integer(nil, default), do: {:ok, default}

  defp integer(value, _default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, {:invalid_value, "startIndex and count must be integers"}}
    end
  end

  @doc "Sends a `ListResponse` of `resources`, one page of `total`."
  def list(conn, total, start_index, resources) do
    json(conn, 200, %{
      "schemas" => [Schemas.list_response_schema()],
      "totalResults" => total,
      "startIndex" => start_index,
      "itemsPerPage" => length(resources),
      "Resources" => resources
    })
  end

  @doc """
  The operations of a `PatchOp` body. The `schemas` value is not required,
  since some providers leave it out, but a body naming other schemas only is
  refused.
  """
  def operations(body) do
    schemas = Attributes.get(body, "schemas")

    case Attributes.fetch(body, "Operations") do
      {:ok, operations} when is_list(operations) and operations != [] ->
        if is_nil(schemas) or (is_list(schemas) and @patch_schema in schemas),
          do: {:ok, operations},
          else: {:error, {:invalid_syntax, "The body must be a PatchOp message"}}

      _missing ->
        {:error, {:invalid_syntax, "The body must carry a list of Operations"}}
    end
  end
end
