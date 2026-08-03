defmodule RengaWeb.Api.AgentController do
  use RengaWeb, :controller

  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload

  def check_in(%{assigns: %{current_source: %{kind: "host_agent"} = source}} = conn, params) do
    with {:ok, attrs} <- AgentPayload.validate_check_in(params, source),
         {:ok, {agent, lease}} <-
           Inventory.record_agent_check_in(conn.assigns.current_scope, source.id, attrs) do
      conn
      |> put_status(:accepted)
      |> json(%{
        status: "accepted",
        source: %{
          id: source.id,
          kind: source.kind,
          name: source.name,
          last_seen_at: DateTime.to_iso8601(lease.renewed_at)
        },
        agent: %{
          id: agent.id,
          name: agent.name,
          lease_expires_at: DateTime.to_iso8601(lease.expires_at)
        }
      })
    else
      {:error, errors} when is_list(errors) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "rejected", errors: errors})
    end
  end

  def check_in(conn, _params) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: [%{path: "source.kind", message: "must be host_agent"}]})
  end
end
