defmodule Renga.Jobs.Capabilities.InventoryCollect do
  @moduledoc """
  `inventory.collect@1`: run the agent's normal inventory collection now.

  The job adds no power over the host. Its one host observation uses an
  attempt-bound protected reservation; success requires durable acceptance
  of that exact observation, not local enqueue or canonical reconciliation.
  """

  use Renga.Jobs.Capability

  import Ecto.Changeset

  @impl true
  def name, do: "inventory.collect"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Collect inventory"

  @impl true
  def noun, do: "Inventory collection"

  @impl true
  def risk_class, do: :observe

  @impl true
  def retry_class, do: :idempotent

  @impl true
  def timeout_ms, do: :timer.minutes(5)

  @impl true
  def evidence_limit,
    do: %{items: 1, bytes: Renga.Inventory.AgentPayload.max_observation_bytes()}

  @impl true
  def result_evidence_ids(result), do: [result["observation_id"]]

  @impl true
  def parameters_changeset(params) do
    # No parameters: a collection is always the agent's configured one.
    {%{}, %{}}
    |> cast(params, [])
    |> reject_unknown(params, [])
  end

  @impl true
  def result_changeset(result) do
    {%{}, %{observation_id: Ecto.UUID}}
    |> cast(result, [:observation_id])
    |> validate_required([:observation_id])
    |> reject_unknown(result, ["observation_id"])
  end

  @impl true
  def describe_result(%{"observation_id" => observation_id}),
    do: "Collected observation #{observation_id}"

  def describe_result(_result), do: "Collected"

  defp reject_unknown(changeset, params, known) do
    case Map.keys(params) -- known do
      [] -> changeset
      unknown -> add_error(changeset, :base, "unknown fields: #{Enum.join(unknown, ", ")}")
    end
  end
end
