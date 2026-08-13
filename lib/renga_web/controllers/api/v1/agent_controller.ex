defmodule RengaWeb.Api.V1.AgentController do
  use RengaWeb, :controller

  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.Source

  def check_in(%{assigns: %{current_intake_api_key: intake_api_key}} = conn, params) do
    source_identity = %Source{kind: "host_agent"}

    with {:ok, attrs} <- AgentPayload.validate_check_in(params, source_identity),
         {:ok, {agent, lease}} <-
           Inventory.record_intake_agent_check_in(
             conn.assigns.current_scope,
             intake_api_key,
             conn.assigns.current_installation_id,
             attrs
           ) do
      source = Inventory.get_source!(conn.assigns.current_scope, agent.source_id)
      accepted(conn, source, agent, lease)
    else
      error -> check_in_error(conn, error)
    end
  end

  def check_in(%{assigns: %{current_source: %{kind: "host_agent"} = source}} = conn, params) do
    with {:ok, attrs} <- AgentPayload.validate_check_in(params, source),
         {:ok, {agent, lease}} <-
           Inventory.record_authenticated_agent_check_in(
             conn.assigns.current_scope,
             source,
             Map.put(attrs, :installation_id, conn.assigns.current_installation_id)
           ) do
      accepted(conn, source, agent, lease)
    else
      error -> check_in_error(conn, error)
    end
  end

  def check_in(conn, _params) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: [%{path: "source.kind", message: "must be host_agent"}]})
  end

  defp accepted(conn, source, agent, lease) do
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
  end

  defp check_in_error(conn, {:error, reason})
       when reason in [:source_credential_changed, :intake_credential_changed] do
    conn
    |> put_status(:unauthorized)
    |> json(%{status: "rejected", errors: [%{path: "authorization", message: "is invalid"}]})
  end

  defp check_in_error(conn, {:error, reason})
       when reason in [:installation_identity_mismatch, :installation_identity_conflict] do
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
  end

  defp check_in_error(conn, {:error, errors}) when is_list(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "rejected", errors: errors})
  end

  defp check_in_error(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "rejected", errors: changeset_errors(changeset, "agent")})
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
