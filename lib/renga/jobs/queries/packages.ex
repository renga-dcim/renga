defmodule Renga.Jobs.Queries.Packages do
  @moduledoc """
  `query.packages@1`: installed packages and their versions, from the host's
  package database (RFD 12). Sensitive: versions are what an attacker looks
  for. A host has more packages than one result holds, so `name` narrows the
  list to packages whose name contains it, and `truncated` says when it was
  cut short.
  """

  use Renga.Jobs.Query

  @impl true
  def name, do: "query.packages"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Packages"

  @impl true
  def noun, do: "Packages query"

  @impl true
  def summary, do: "Installed packages and versions, bounded and filterable by name"

  @impl true
  def sensitivity, do: :sensitive

  @impl true
  def timeout_ms, do: :timer.seconds(60)

  @impl true
  def parameters_schema, do: {:object, [{"name", {:optional, {:string, max: 128}}}]}

  @impl true
  def result_schema do
    {:object,
     [
       {"packages",
        {:list,
         {:object,
          [
            {"name", {:string, max: 256}},
            {"version", {:string, max: 256}},
            {"architecture", {:nullable, {:string, max: 32}}},
            {"manager", {:enum, ~w(dpkg rpm apk pacman)}}
          ]}, max: 4096}},
       {"truncated", :boolean}
     ]}
  end

  @impl true
  def describe_result(%{"packages" => [_package]}), do: "1 package"
  def describe_result(%{"packages" => packages}), do: "#{length(packages)} packages"
  def describe_result(_result), do: "Completed"
end
