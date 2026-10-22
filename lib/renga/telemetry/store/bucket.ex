defmodule Renga.Telemetry.Store.Bucket do
  @moduledoc """
  One fixed-width bucket of a series, as `Renga.Telemetry.Store.range/5`
  reads it: the average, minimum, maximum, and last of its samples, and how
  many there were. A bucket without samples is a gap: its count is zero and
  its values are nil, never zero.
  """

  @enforce_keys [:start]
  defstruct [:start, :average, :minimum, :maximum, :last, count: 0]

  @type t :: %__MODULE__{
          start: DateTime.t(),
          average: float() | nil,
          minimum: float() | nil,
          maximum: float() | nil,
          last: float() | nil,
          count: non_neg_integer()
        }

  @doc "An empty bucket starting at `start`."
  def gap(%DateTime{} = start), do: %__MODULE__{start: start}

  def gap?(%__MODULE__{count: count}), do: count == 0
end
