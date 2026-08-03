defmodule Renga.Types.Cidr do
  @moduledoc """
  Ecto type for PostgreSQL `cidr` network prefixes.

  Parsing is shared with `Renga.Types.Inet`; PostgreSQL's `cidr` type then
  enforces network-prefix semantics instead of accepting an arbitrary host IP.
  """

  use Ecto.Type

  alias Renga.Types.Inet

  def type, do: :cidr
  def cast(value), do: Inet.cast(value)
  def dump(value), do: Inet.dump(value)
  def load(value), do: Inet.load(value)
end
