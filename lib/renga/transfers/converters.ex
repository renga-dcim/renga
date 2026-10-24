defmodule Renga.Transfers.Converters do
  @moduledoc """
  Converters from earlier archive format versions (RFD 20).

  A migration that changes an exported record's shape bumps
  `Renga.Transfers.Archive.format_version/0` and adds a converter here from
  the version before, with a round-trip fixture of the old version
  (`test/fixtures/transfers/`). A converter is a module whose
  `convert(type, record)` returns `record`, of record type `type`, as the
  next format version holds it, and whose `added_types()` lists the record
  types the next version adds, which an older archive holds none of.

  Opening an older archive chains the converters from its version to this
  release's, and `Renga.Transfers.Archive.records/2` converts every record as
  it is read, so validation and import only see the current format.

  Format version 1 is the first, so there are none yet.
  """

  # %{from format version => converter to the next version}
  @converters %{}

  @doc "The format versions there is a converter from."
  def versions, do: @converters |> Map.keys() |> Enum.sort()

  @doc """
  The converters from format `version` to `current`, in order: `{:ok, []}`
  for the current version, `:error` when any is missing.
  """
  def chain(version, current, converters \\ @converters)
  def chain(current, current, _converters), do: {:ok, []}

  def chain(version, current, converters) when version < current do
    with {:ok, converter} <- Map.fetch(converters, version),
         {:ok, rest} <- chain(version + 1, current, converters),
         do: {:ok, [converter | rest]}
  end

  def chain(_version, _current, _converters), do: :error

  @doc "The record types the converters of `chain` add."
  def added_types(chain), do: Enum.flat_map(chain, & &1.added_types())

  @doc "Passes `record`, of record type `type`, through each converter of `chain`."
  def convert(record, type, chain),
    do: Enum.reduce(chain, record, fn converter, record -> converter.convert(type, record) end)
end
