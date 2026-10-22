defmodule RengaWeb.Operator.V1.Schemas do
  @moduledoc """
  Shared pieces of the operator API's OpenAPI document.
  """

  @doc "The response every operator endpoint gives while the API is off."
  def disabled_response do
    {RengaWeb.Operator.V1.Schemas.Error,
     description:
       "The operator API is off because no operator token can authenticate. Every request " <>
         "gets this response, whatever its path."}
  end

  @doc "The response every operator endpoint gives when authentication fails."
  def unauthorized_response do
    {RengaWeb.Operator.V1.Schemas.Error,
     description:
       "The operator token is missing, unknown, revoked, expired, or used from an " <>
         "address it does not allow."}
  end

  @doc "The header every non-idempotent write requires (RFD 22, \"Writes\")."
  def idempotency_key_parameter do
    [
      in: :header,
      required: true,
      schema: %{type: :string, minLength: 1, maxLength: 255},
      description:
        "Names this write so a retry returns its result instead of acting again. Keys " <>
          "are per token, method, and route, and are kept for " <>
          "#{Renga.Operators.Idempotency.retention_hours()} hours. Reusing a key for a " <>
          "different request is refused with `409`."
    ]
  end

  @doc "The responses every non-idempotent write can give besides its own."
  def write_responses do
    [
      bad_request:
        {RengaWeb.Operator.V1.Schemas.Error,
         description:
           "The `Idempotency-Key` header is missing or malformed, or the body is not a " <>
             "JSON object."},
      unauthorized: unauthorized_response(),
      forbidden:
        {RengaWeb.Operator.V1.Schemas.Error,
         description: "The token lacks the scope this operation needs."},
      conflict:
        {RengaWeb.Operator.V1.Schemas.Error,
         description: "The `Idempotency-Key` was already used for a different request."}
    ]
  end
end
