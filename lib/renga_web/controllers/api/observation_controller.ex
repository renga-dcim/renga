defmodule RengaWeb.Api.ObservationController do
  use RengaWeb, :controller

  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload

  def create(%{assigns: %{current_source: %{kind: "host_agent"} = source}} = conn, params) do
    with {:ok, attrs} <- AgentPayload.validate_observation(params, source),
         {:ok, observation, disposition} <-
           Inventory.accept_observation(conn.assigns.current_scope, source.id, attrs),
         {:ok, {_agent, _lease}} <-
           Inventory.record_agent_check_in(conn.assigns.current_scope, source.id) do
      conn
      |> put_status(status_for(disposition))
      |> json(%{
        status: "accepted",
        duplicate: disposition == :duplicate,
        observation: %{
          id: observation.id,
          observation_id: observation.idempotency_key,
          observed_at: DateTime.to_iso8601(observation.observed_at),
          source_id: observation.source_id
        }
      })
    else
      {:error, :idempotency_conflict, observation} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          status: "rejected",
          errors: [
            %{
              path: "observation_id",
              message: "has already been used for a different payload",
              observation_id: observation.id
            }
          ]
        })

      {:error, errors} when is_list(errors) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "rejected", errors: errors})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: [%{path: "source.kind", message: "must be host_agent"}]})
  end

  defp status_for(:created), do: :accepted
  defp status_for(:duplicate), do: :ok
end
