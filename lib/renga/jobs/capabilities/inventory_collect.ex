defmodule Renga.Jobs.Capabilities.InventoryCollect do
  @moduledoc """
  `inventory.collect@1`: run the agent's normal inventory collection now.

  The first job type is deliberately harmless (RFD 9). The agent delivers the
  observation through its ordinary queue and reports only the observation's
  ID, so the job adds no power over the host and running it again just
  produces another, deduplicated observation.
  """

  use Renga.Jobs.Capability

  import Ecto.Changeset

  @impl true
  def name, do: "inventory.collect"

  @impl true
  def version, do: 1

  @impl true
  def risk_class, do: :observe

  @impl true
  def retry_class, do: :idempotent

  @impl true
  def timeout_ms, do: :timer.minutes(5)

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
