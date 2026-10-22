defmodule Renga.Jobs.Queries.TimeSync do
  @moduledoc """
  `query.time_sync@1`: whether the clock is synchronized, its estimated
  error, and, where the time daemon says, the source it follows (RFD 12).
  """

  use Renga.Jobs.Query

  @impl true
  def name, do: "query.time_sync"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Time sync"

  @impl true
  def noun, do: "Time sync query"

  @impl true
  def summary, do: "Clock synchronization source, offset, and status"

  @impl true
  def sensitivity, do: :inventory

  @impl true
  def parameters_schema, do: {:object, []}

  @impl true
  def result_schema do
    {:object,
     [
       {"synchronized", :boolean},
       {"daemon", {:nullable, {:string, max: 64}}},
       {"source", {:nullable, {:string, max: 256}}},
       {"stratum", {:nullable, {:integer, min: 0, max: 16}}},
       {"offset_us", {:nullable, :integer}},
       {"max_error_us", {:nullable, {:integer, min: 0}}},
       {"estimated_error_us", {:nullable, {:integer, min: 0}}}
     ]}
  end

  @impl true
  def describe_result(%{"synchronized" => true}), do: "Synchronized"
  def describe_result(%{"synchronized" => false}), do: "Not synchronized"
  def describe_result(_result), do: "Completed"
end
