defmodule RengaWeb.Api.V1.ObservationController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.ReconciliationWork
  alias Renga.Inventory.Source
  alias RengaWeb.Api.V1.Schemas

  tags ["Intake"]
  parameter :"x-renga-installation-id", Schemas.installation_id_parameter()

  operation :create,
    operation_id: "createObservation",
    summary: "Submit an observation",
    description:
      "Stores a point-in-time report about the collector's host, or from one of its " <>
        "collector modules, with a durable receipt. Reconciliation runs independently. " <>
        "Identical replay reuses the first receipt without another pending reservation.",
    security: Schemas.intake_security(),
    request_body: Schemas.Observation,
    responses: [
      accepted: {Schemas.ObservationAccepted, description: "Observation stored."},
      ok:
        {Schemas.ObservationAccepted,
         description: "This observation ID was already stored with the same payload."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "The organization is suspended."},
      too_many_requests:
        {Schemas.Rejected,
         description: "Capacity exhausted. Retry no earlier than Retry-After seconds."},
      request_entity_too_large:
        {Schemas.Rejected, description: "The encoded observation exceeds the intake size bound."},
      conflict:
        {Schemas.Rejected,
         description:
           "The installation ID is registered to a different collector source, the " <>
             "`observation_id` was already used for a different payload, or the named " <>
             "collector is disabled or registered with a different kind."},
      unprocessable_entity: {Schemas.Rejected, description: "The observation is invalid."}
    ]

  def create(%{assigns: %{current_intake_api_key: intake_api_key}} = conn, params) do
    source_identity = %Source{kind: reported_kind(params)}

    with {:ok, attrs} <- AgentPayload.validate_observation(params, source_identity),
         {:ok, {_agent, _lease, observation, disposition}} <-
           Inventory.ingest_intake_observation(
             conn.assigns.current_scope,
             intake_api_key,
             conn.assigns.current_installation_id,
             %{},
             Map.put(attrs, :reported_from, reported_from(conn))
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

  operation :receipt,
    operation_id: "getObservationReceipt",
    summary: "Inspect an existing durable receipt",
    description:
      "Read-only lookup scoped to the authenticated installation and an existing collector stream. " <>
        "Does not register a source, renew a lease or schedule processing. Only exact-body POST replay proves body acceptance.",
    security: Schemas.intake_security(),
    parameters: [
      observation_id: [in: :query, required: true, schema: %{type: :string}],
      collector_id: [in: :query, required: false, schema: %{type: :string}]
    ],
    responses: [
      ok:
        {Schemas.ObservationAccepted,
         description: "The original receipt and current processing state."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Rejected, description: "Organization or installation is disabled."},
      not_found:
        {Schemas.Rejected, description: "No receipt owned by this installation and stream."},
      conflict: {Schemas.Rejected, description: "Installation has not registered."},
      unprocessable_entity: {Schemas.Rejected, description: "Missing or invalid observation ID."},
      too_many_requests:
        {Schemas.Rejected, description: "Retry no earlier than Retry-After seconds."}
    ]

  def receipt(conn, %{"observation_id" => id} = params) when is_binary(id) do
    collector = params["collector_id"]

    if is_nil(collector) or is_binary(collector) do
      case Inventory.intake_observation_receipt(
             conn.assigns.current_scope,
             conn.assigns.current_intake_api_key,
             conn.assigns.current_installation_id,
             id,
             collector
           ) do
        {:ok, accepted} -> respond_to_accepted_observation(conn, accepted.observation, :duplicate)
        error -> observation_error(conn, error)
      end
    else
      receipt(conn, %{})
    end
  end

  def receipt(conn, _params),
    do:
      observation_error(conn, {:error, [%{path: "observation_id", message: "must be a string"}]})

  # Collector reports are checked against the collector's kind; the stream
  # itself is resolved from the installation and collector ID at ingest.
  defp reported_kind(%{"collector" => %{"kind" => kind}}) when is_binary(kind), do: kind
  defp reported_kind(_params), do: "host_agent"

  # The address the endpoint saw. Behind a proxy, deployments rewrite
  # `remote_ip` from forwarding headers before it reaches here.
  defp reported_from(%{remote_ip: address}) when is_tuple(address),
    do: %Postgrex.INET{address: address, netmask: nil}

  defp reported_from(_conn), do: nil

  defp respond_to_accepted_observation(conn, observation, disposition) do
    accepted = ReconciliationWork.accepted(conn.assigns.current_scope, observation)

    conn
    |> put_status(status_for(disposition))
    |> json(%{
      status: "accepted",
      duplicate: disposition == :duplicate,
      receipt: %{
        id: accepted.receipt.work_id,
        position: accepted.receipt.position,
        accepted_at: accepted.receipt.accepted_at
      },
      processing: %{status: accepted.work.status},
      observation: %{
        id: observation.id,
        observation_id: observation.idempotency_key,
        observed_at: DateTime.to_iso8601(observation.observed_at),
        source_id: observation.source_id
      }
    })
  end

  defp observation_error(conn, {:error, :organization_inactive}) do
    conn
    |> put_status(:forbidden)
    |> json(%{status: "rejected", errors: [%{path: "organization", message: "is suspended"}]})
  end

  defp observation_error(conn, {:error, :forbidden}),
    do: observation_error(conn, {:error, :organization_inactive})

  defp observation_error(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{status: "rejected", errors: [%{path: "observation_id", message: "not found"}]})
  end

  defp observation_error(conn, {:error, :agent_not_registered}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      status: "rejected",
      errors: [%{path: "installation_id", message: "not registered"}]
    })
  end

  defp observation_error(conn, {:error, :agent_disabled}) do
    conn
    |> put_status(:forbidden)
    |> json(%{status: "rejected", errors: [%{path: "installation_id", message: "is disabled"}]})
  end

  defp observation_error(conn, {:error, :capacity}) do
    conn
    |> put_resp_header("retry-after", "1")
    |> put_status(:too_many_requests)
    |> json(%{status: "rejected", errors: [%{path: "capacity", message: "pending work is full"}]})
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

  defp observation_error(conn, {:error, :unsupported_existing_observation}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      status: "rejected",
      errors: [%{path: "observation_id", message: "predates durable acceptance"}]
    })
  end

  defp observation_error(conn, {:error, :collector_kind_conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      status: "rejected",
      errors: [%{path: "collector.kind", message: "does not match the collector's kind"}]
    })
  end

  defp observation_error(conn, {:error, :collector_disabled}) do
    conn
    |> put_status(:conflict)
    |> json(%{status: "rejected", errors: [%{path: "collector.id", message: "is disabled"}]})
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
