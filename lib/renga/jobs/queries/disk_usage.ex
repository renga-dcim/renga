defmodule Renga.Jobs.Queries.DiskUsage do
  @moduledoc """
  `query.disk_usage@1`: capacity and use of each mounted filesystem, read
  with `statvfs` (RFD 12). It reports what an inventory snapshot leaves out,
  and is no more revealing than one.
  """

  use Renga.Jobs.Query

  @impl true
  def name, do: "query.disk_usage"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Disk usage"

  @impl true
  def noun, do: "Disk usage query"

  @impl true
  def summary, do: "Filesystem capacity and use, beyond the inventory snapshot"

  @impl true
  def sensitivity, do: :inventory

  @impl true
  def parameters_schema, do: {:object, []}

  @impl true
  def result_schema do
    {:object,
     [
       {"filesystems",
        {:list,
         {:object,
          [
            {"mount_point", {:string, max: 512}},
            {"device", {:string, max: 256}},
            {"fs_type", {:string, max: 32}},
            {"size_bytes", {:integer, min: 0}},
            {"used_bytes", {:integer, min: 0}},
            {"available_bytes", {:integer, min: 0}},
            {"inodes_total", {:nullable, {:integer, min: 0}}},
            {"inodes_used", {:nullable, {:integer, min: 0}}}
          ]}, max: 512}},
       {"truncated", :boolean}
     ]}
  end

  @impl true
  def describe_result(%{"filesystems" => filesystems}),
    do: "#{length(filesystems)} filesystems"

  def describe_result(_result), do: "Completed"
end
