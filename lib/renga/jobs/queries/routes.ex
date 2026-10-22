defmodule Renga.Jobs.Queries.Routes do
  @moduledoc """
  `query.routes@1`: the routing table of each routing domain, read over
  netlink (RFD 12). A route's `table` is the kernel table it lives in, and
  `vrf` names the VRF device bound to that table, if any.
  """

  use Renga.Jobs.Query

  @impl true
  def name, do: "query.routes"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Routes"

  @impl true
  def noun, do: "Routes query"

  @impl true
  def summary, do: "The routing table per routing domain"

  @impl true
  def sensitivity, do: :inventory

  @impl true
  def parameters_schema, do: {:object, [{"family", {:optional, {:enum, ~w(ipv4 ipv6)}}}]}

  @impl true
  def result_schema do
    {:object,
     [
       {"routes",
        {:list,
         {:object,
          [
            {"table", {:integer, min: 0}},
            {"vrf", {:nullable, {:string, max: 64}}},
            {"family", {:enum, ~w(ipv4 ipv6)}},
            {"destination", {:string, max: 64}},
            {"gateway", {:nullable, {:string, max: 64}}},
            {"interface", {:nullable, {:string, max: 64}}},
            {"metric", {:nullable, {:integer, min: 0}}},
            {"protocol", {:nullable, {:string, max: 32}}}
          ]}, max: 4096}},
       {"truncated", :boolean}
     ]}
  end

  @impl true
  def describe_result(%{"routes" => routes}), do: "#{length(routes)} routes"
  def describe_result(_result), do: "Completed"
end
