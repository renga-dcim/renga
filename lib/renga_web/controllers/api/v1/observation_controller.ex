defmodule RengaWeb.Api.V1.ObservationController do
  use RengaWeb, :controller

  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Source

  def create(%{assigns: %{current_intake_api_key: intake_api_key}} = conn, params) do
    source_identity = %Source{kind: "host_agent"}

    with {:ok, attrs} <- AgentPayload.validate_observation(params, source_identity),
         {:ok, {_agent, _lease, observation, disposition}} <-
           Inventory.ingest_intake_observation(
             conn.assigns.current_scope,
             intake_api_key,
             conn.assigns.current_installation_id,
             %{},
             attrs
           ) do
      respond_to_accepted_observation(conn, observation, disposition)
    else
      error -> observation_error(conn, error)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: [%{path: "source.kind", message: "must be host_agent"}]})
  end

  defp respond_to_accepted_observation(conn, observation, disposition) do
    reconciliation =
      reconcile_observation(conn.assigns.current_scope, observation, disposition)

    conn
    |> put_status(status_for(disposition))
    |> json(%{
      status: "accepted",
      duplicate: disposition == :duplicate,
      reconciliation: reconciliation,
      observation: %{
        id: observation.id,
        observation_id: observation.idempotency_key,
        observed_at: DateTime.to_iso8601(observation.observed_at),
        source_id: observation.source_id
      }
    })
  end

  defp observation_error(conn, {:error, :intake_credential_changed}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{status: "rejected", errors: [%{path: "authorization", message: "is invalid"}]})
  end

  defp observation_error(conn, {:error, :installation_identity_conflict}) do
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

  defp observation_error(conn, {:error, :idempotency_conflict, observation}) do
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
  end

  defp observation_error(conn, {:error, errors}) when is_list(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "rejected", errors: errors})
  end

  defp observation_error(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{status: "rejected", errors: changeset_errors(changeset, "agent")})
  end

  defp status_for(:created), do: :accepted
  defp status_for(:duplicate), do: :ok

  defp reconcile_observation(scope, observation, disposition) do
    case Inventory.reconcile_observation_once(scope, observation.id) do
      {:ok, resource, _discovered?} ->
        %{status: "succeeded", matched_resource_id: resource.id}

      {:error, %ObservationReconciliation{} = result} when disposition == :duplicate ->
        %{
          status: "failed",
          matched_resource_id: result.matched_resource_id,
          errors: result.errors
        }

      {:error, %ObservationReconciliation{} = result} ->
        %{status: "failed", errors: result.errors}

      {:error, _reason} ->
        %{status: "failed", errors: %{"processing" => "reconciliation_failed"}}
    end
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
