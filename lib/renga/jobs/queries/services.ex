defmodule Renga.Jobs.Queries.Services do
  @moduledoc """
  `query.services@1`: systemd service units and their load, active, and
  enablement states, read over systemd's D-Bus interface (RFD 12).
  Sensitive: it shows what a host runs.
  """

  use Renga.Jobs.Query

  @impl true
  def name, do: "query.services"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Services"

  @impl true
  def noun, do: "Services query"

  @impl true
  def summary, do: "systemd units and their active, failed, and enabled states"

  @impl true
  def sensitivity, do: :sensitive

  @impl true
  def parameters_schema, do: {:object, [{"failed_only", {:optional, :boolean}}]}

  @impl true
  def result_schema do
    {:object,
     [
       {"units",
        {:list,
         {:object,
          [
            {"name", {:string, max: 256}},
            {"description", {:nullable, {:string, max: 256}}},
            {"load_state", {:string, max: 32}},
            {"active_state", {:string, max: 32}},
            {"sub_state", {:string, max: 32}},
            {"enabled_state", {:nullable, {:string, max: 32}}}
          ]}, max: 4096}},
       {"truncated", :boolean}
     ]}
  end

  @impl true
  def describe_result(%{"units" => units}) do
    failed = Enum.count(units, &(&1["active_state"] == "failed"))
    "#{length(units)} units, #{failed} failed"
  end

  def describe_result(_result), do: "Completed"
end
