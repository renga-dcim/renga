defmodule RengaWeb.JSON do
  @moduledoc false

  def decode(value, options \\ []), do: Jason.decode(value, options)
  def decode!(value, options \\ []), do: Jason.decode!(value, options)

  def encode(value, _options \\ []), do: Renga.JSON.encode(value)
  def encode!(value, _options \\ []), do: Renga.JSON.encode!(value)
  def encode_to_iodata!(value, _options \\ []), do: Renga.JSON.encode_to_iodata!(value)
end
