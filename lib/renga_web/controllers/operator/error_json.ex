defmodule RengaWeb.Operator.ErrorJSON do
  @moduledoc """
  Renders the operator endpoint's own errors, such as an unknown route or a
  malformed body, in the same `{"error": code}` shape as its authentication
  errors, rather than the main endpoint's.
  """

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    %{error: message |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")}
  end
end
