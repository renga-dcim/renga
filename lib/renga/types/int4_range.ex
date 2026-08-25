defmodule Renga.Types.Int4Range do
  @moduledoc "Ecto type for PostgreSQL's bounded integer range."
  use Ecto.Type

  def type, do: :int4range
  def cast(%Postgrex.Range{} = range), do: {:ok, range}
  def cast(_value), do: :error
  def load(%Postgrex.Range{} = range), do: {:ok, range}
  def dump(%Postgrex.Range{} = range), do: {:ok, range}
end
