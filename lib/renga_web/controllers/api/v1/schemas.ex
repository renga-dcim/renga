defmodule RengaWeb.Api.V1.Schemas do
  @moduledoc """
  Building blocks for the JSON Schemas (2020-12) in the v1 OpenAPI document.

  The schemas document the machine API; `Renga.Inventory.AgentPayload` and the
  job controller remain the validators. A request schema must never reject a
  request those accept, or it would mislead client authors, so request
  schemas:

  * leave objects open where the API ignores unknown fields, so a newer agent
    can add some;
  * allow `null` wherever the API treats it as absent;
  * state lengths the API counts in characters (grapheme clusters) in prose,
    because JSON Schema's `maxLength` counts code points and would reject
    accepted strings that use combining marks;
  * say "not blank" in prose rather than with a `pattern`, because the API's
    notion of whitespace (`String.trim/1`) differs from ECMA-262's `\\s`.

  Rules that span fields or depend on server state, such as identifiers
  matching interfaces, also stay in prose. Response schemas are exact.
  """

  alias Renga.Inventory.AgentPayload

  @doc "The vocabularies and limits the schemas share with `AgentPayload`."
  def contract, do: AgentPayload.contract()

  @doc "A string the API bounds by its usual length in characters."
  def string(description \\ nil),
    do: %{type: :string, description: describe([description, length_note()])}

  @doc "A non-blank string the API bounds by its usual length in characters."
  def non_blank_string(description \\ nil) do
    %{
      type: :string,
      minLength: 1,
      description: describe([description, blank_note(), length_note()])
    }
  end

  @doc """
  A non-blank string the API also bounds in code points, which `maxLength`
  counts exactly.
  """
  def code_point_bounded_string(description \\ nil) do
    %{
      type: :string,
      minLength: 1,
      maxLength: contract().max_string_length,
      description: describe([description, blank_note()])
    }
  end

  @doc "Allows `null` alongside the given schema."
  def nullable(%{type: type} = schema) when is_atom(type), do: %{schema | type: [type, :null]}
  def nullable(schema), do: %{anyOf: [schema, %{type: :null}]}

  @doc "A UUID, as the server renders record IDs."
  def uuid(description \\ nil),
    do: maybe_describe(%{type: :string, format: :uuid}, description)

  @doc "A timestamp as the server renders it (RFC 3339)."
  def timestamp(description \\ nil),
    do: maybe_describe(%{type: :string, format: :"date-time"}, description)

  @doc """
  A timestamp as the API parses it: ISO 8601 with a UTC offset. That admits
  forms RFC 3339's `date-time` format does not, such as `+0100` offsets and
  comma fractions, so it is not declared as that format.
  """
  def iso8601_timestamp(description \\ nil) do
    %{
      type: :string,
      description:
        describe([
          description,
          "An ISO 8601 date and time with a UTC offset, such as 2026-01-02T03:04:05Z."
        ])
    }
  end

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
        "The collector installation's stable UUID. Within the intake key's organization " <>
          "it selects the collector, registering one on first use, so one key can enroll " <>
          "a whole fleet."
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

  defp blank_note, do: "Must not be blank."
  defp length_note, do: "At most #{contract().max_string_length} characters."

  defp describe(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  defp maybe_describe(schema, nil), do: schema
  defp maybe_describe(schema, description), do: Map.put(schema, :description, description)
end
