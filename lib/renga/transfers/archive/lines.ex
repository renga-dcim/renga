defmodule Renga.Transfers.Archive.Lines do
  @moduledoc """
  Splits a stream of chunks into newline-terminated lines without holding
  more than one line, so a record file cannot make the reader buffer an
  unbounded line.

  `feed/2` returns the items its chunk completes:

    * `{:line, line}`, a complete line without its newline;
    * `{:too_long, bytes}`, a line longer than the limit, which is dropped
      while it streams past;

  and `finish/1` returns `:unterminated` when the input did not end with a
  newline.
  """

  defstruct max: :infinity, buffer: [], size: 0, skipping: false

  @doc "A splitter that allows lines up to `max` bytes, or `:infinity`."
  def new(max), do: %__MODULE__{max: max}

  @doc "Splits `chunks` into items as a stream."
  def stream(chunks, max) do
    Stream.transform(
      chunks,
      fn -> new(max) end,
      fn chunk, lines -> feed(lines, chunk) end,
      fn lines -> {finish(lines), lines} end,
      fn _lines -> :ok end
    )
  end

  @doc "Feeds one chunk, returning the items it completes and the new state."
  def feed(%__MODULE__{} = lines, chunk) do
    case :binary.split(chunk, "\n") do
      [rest] ->
        {[], append(lines, rest)}

      [head, rest] ->
        lines = append(lines, head)
        {item, lines} = take(lines)
        {items, lines} = feed(lines, rest)
        {[item | items], lines}
    end
  end

  @doc "Ends the input, returning `[:unterminated]` if a line was left open."
  def finish(%__MODULE__{size: 0, skipping: false}), do: []
  def finish(%__MODULE__{}), do: [:unterminated]

  defp append(%__MODULE__{skipping: true} = lines, part),
    do: %{lines | size: lines.size + byte_size(part)}

  defp append(%__MODULE__{} = lines, part) do
    size = lines.size + byte_size(part)

    if lines.max != :infinity and size > lines.max,
      do: %{lines | buffer: [], size: size, skipping: true},
      else: %{lines | buffer: [lines.buffer | part], size: size}
  end

  defp take(%__MODULE__{skipping: true} = lines),
    do: {{:too_long, lines.size}, %{lines | buffer: [], size: 0, skipping: false}}

  defp take(%__MODULE__{} = lines),
    do: {{:line, IO.iodata_to_binary(lines.buffer)}, %{lines | buffer: [], size: 0}}
end
