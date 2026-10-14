defmodule RengaWeb.Api.V1.Schemas do
  @moduledoc """
  Building blocks for the JSON Schemas (2020-12) in the v1 OpenAPI document.

  The schemas document the intake API; `Renga.Inventory.AgentPayload` remains
  the validator. Request schemas therefore describe what that module accepts
  and leave objects open where it ignores unknown fields, so a newer agent can
  add some. Rules that span fields or depend on server state, such as
  identifiers matching interfaces, stay in prose descriptions.
  """

  alias Renga.Inventory.AgentPayload

  @doc "The vocabularies and limits the schemas share with `AgentPayload`."
  def contract, do: AgentPayload.contract()

  @doc "A string of at most the API's usual length."
  def string(description \\ nil) do
    maybe_describe(%{type: :string, maxLength: contract().max_string_length}, description)
  end

  @doc "A string that must contain a non-whitespace character."
  def non_blank_string(description \\ nil) do
    maybe_describe(
      %{type: :string, minLength: 1, maxLength: contract().max_string_length, pattern: "\\S"},
      description
    )
  end

  @doc "Allows `null` alongside the given schema."
  def nullable(%{type: type} = schema), do: %{schema | type: [type, :null]}

  @doc "A UUID, as the server renders record IDs."
  def uuid(description \\ nil),
    do: maybe_describe(%{type: :string, format: :uuid}, description)

  @doc "An RFC 3339 timestamp."
  def timestamp(description \\ nil),
    do: maybe_describe(%{type: :string, format: :"date-time"}, description)

  @doc "An object whose shape the API does not constrain."
  def free_object(description \\ nil),
    do: maybe_describe(%{type: :object}, description)

  @doc """
  Forbids the given keys: the API rejects them because the server assigns
  them itself.
  """
  def forbidden(keys), do: Map.new(keys, &{&1, false})

  @doc "The header naming the collector installation on every intake request."
  def installation_id_parameter do
    [
      in: :header,
      required: true,
      schema: uuid(),
      description:
        "The collector installation's stable UUID. An intake key is bound to the first " <>
          "installation that uses it."
    ]
  end

  @doc "Intake endpoints authenticate with an organization intake key."
  def intake_security, do: [%{"intakeKey" => []}]

  @doc "The response every intake endpoint gives when authentication fails."
  def unauthorized_response do
    {RengaWeb.Api.V1.Schemas.Rejected,
     description:
       "The intake key or installation header is missing or invalid, or the key changed " <>
         "while the request was in flight."}
  end

  defp maybe_describe(schema, nil), do: schema
  defp maybe_describe(schema, description), do: Map.put(schema, :description, description)
end
