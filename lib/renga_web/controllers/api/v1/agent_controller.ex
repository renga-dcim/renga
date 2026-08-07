defmodule RengaWeb.Api.V1.AgentController do
  use RengaWeb, :controller

  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload

  def check_in(%{assigns: %{current_source: %{kind: "host_agent"} = source}} = conn, params) do
    with {:ok, attrs} <- AgentPayload.validate_check_in(params, source),
         {:ok, {agent, lease}} <-
           Inventory.record_agent_check_in(
             conn.assigns.current_scope,
             source.id,
             Map.put(attrs, :installation_id, conn.assigns.current_installation_id)
           ) do
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
      {:error, reason}
      when reason in [:installation_identity_mismatch, :installation_identity_conflict] ->
        conn
        |> put_status(:conflict)
        |> json(%{
          status: "rejected",
          errors: [
            %{
              path: "installation_id",
              message: "collector credential is already enrolled by another installation"
            }
          ]
        })

      {:error, errors} when is_list(errors) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "rejected", errors: errors})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "rejected", errors: changeset_errors(changeset, "agent")})
    end
  end

  def check_in(conn, _params) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: [%{path: "source.kind", message: "must be host_agent"}]})
  end

  defp changeset_errors(changeset, prefix) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{path: "#{prefix}.#{field}", message: &1})
    end)
  end
end
