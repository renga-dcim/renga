defmodule Renga.Jobs.Queries.Sql do
  @moduledoc """
  `query.sql@1`: an operator-written osquery `SELECT`, answered by the host's
  own `osqueryd` (RFD 12). It is the one query whose text comes from the
  request, so it is always sensitive and, like every query, off until an
  organization allows it.

  Renga does not parse the SQL. Tables that read files, make network
  requests, or copy files off the host are disabled in osquery itself, and
  the agent refuses to run unless the daemon's `disable_tables` covers its
  deny list. The result is a bounded table of strings: column names in the
  order osquery gives them, and each row's values in that order.
  """

  use Renga.Jobs.Query

  @max_sql 4096

  @impl true
  def name, do: "query.sql"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "osquery SQL"

  @impl true
  def noun, do: "osquery SQL query"

  @impl true
  def summary, do: "An osquery SELECT, with file and network tables disabled by osquery"

  @impl true
  def sensitivity, do: :sensitive

  @impl true
  def parameters_schema, do: {:object, [{"sql", {:string, min: 1, max: @max_sql}}]}

  @impl true
  def result_schema do
    {:object,
     [
       {"columns", {:list, {:string, max: 128}, max: 256}},
       {"rows", {:list, {:list, {:string, max: 1024}, max: 256}, max: 10_000}},
       {"truncated", :boolean}
     ]}
  end

  @impl true
  def describe_result(%{"rows" => [_row]}), do: "1 row"
  def describe_result(%{"rows" => rows}), do: "#{length(rows)} rows"
  def describe_result(_result), do: "Completed"
end
