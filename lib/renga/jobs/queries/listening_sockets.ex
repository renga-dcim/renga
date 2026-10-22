defmodule Renga.Jobs.Queries.ListeningSockets do
  @moduledoc """
  `query.listening_sockets@1`: listening TCP and UDP sockets with the
  processes that own them, read from procfs (RFD 12). Sensitive: it shows
  which services a host exposes.
  """

  use Renga.Jobs.Query

  @impl true
  def name, do: "query.listening_sockets"

  @impl true
  def version, do: 1

  @impl true
  def title, do: "Listening sockets"

  @impl true
  def noun, do: "Listening sockets query"

  @impl true
  def summary, do: "Listening TCP and UDP sockets with their process names"

  @impl true
  def sensitivity, do: :sensitive

  @impl true
  def parameters_schema do
    {:object, [{"port", {:optional, {:integer, min: 1, max: 65_535}}}]}
  end

  @impl true
  def result_schema do
    {:object,
     [
       {"sockets",
        {:list,
         {:object,
          [
            {"protocol", {:enum, ~w(tcp udp)}},
            {"address", {:string, max: 64}},
            {"port", {:integer, min: 0, max: 65_535}},
            {"process", {:nullable, {:string, max: 64}}},
            {"pid", {:nullable, {:integer, min: 1}}}
          ]}, max: 4096}},
       {"truncated", :boolean}
     ]}
  end

  @impl true
  def describe_result(%{"sockets" => sockets}), do: "#{length(sockets)} listening sockets"
  def describe_result(_result), do: "Completed"
end
