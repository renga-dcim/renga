defmodule RengaWeb.Operator.V1.Schemas do
  @moduledoc """
  Shared pieces of the operator API's OpenAPI document.
  """

  @doc "The response every operator endpoint gives when authentication fails."
  def unauthorized_response do
    {RengaWeb.Operator.V1.Schemas.Error,
     description:
       "The operator token is missing, unknown, revoked, expired, or used from an " <>
         "address it does not allow."}
  end
end
