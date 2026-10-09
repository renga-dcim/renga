defmodule Renga.Catalog.TemplatePattern do
  @moduledoc """
  Name patterns for editing component templates in groups (RFD 8, "Editing
  hardware components"): `DIMM {A,B}{1..16}` stands for the 32 templates
  DIMM A1 through DIMM B16.

  A pattern is literal text with brace groups, each either alternatives
  (`{A,B}`) or a numeric range (`{1..16}`; `{01..16}` keeps the zero
  padding). Expanding takes every combination, the first group outermost.

  `compress/1` goes the other way so a revision's templates can be shown
  and edited as groups: templates that differ only in a trailing slot
  token (an optional letter and a number) and share everything else
  collapse into one pattern. Compressing then expanding gives back the
  same names and positions.
  """

  alias Renga.Catalog.TemplatePattern.Group

  @max_names 1024

  @doc """
  Expands a pattern into its names, in order.

      iex> Renga.Catalog.TemplatePattern.expand("DIMM {A,B}{1..2}")
      {:ok, ["DIMM A1", "DIMM A2", "DIMM B1", "DIMM B2"]}
  """
  def expand(pattern) when is_binary(pattern) do
    with {:ok, parts} <- parse(String.trim(pattern)),
         :ok <- check_size(parts) do
      {:ok, combinations(parts)}
    end
  end

  def expand(_pattern), do: {:error, "enter a name or pattern"}

  @doc """
  Expands a name pattern and an optional position pattern into
  `{name, position}` pairs. Without a position pattern each position is
  the slot token ending the name (`A1` for `DIMM A1`), else the text its
  brace groups produced, else nil. A position pattern must give as many positions
  as there are names.
  """
  def expand_slots(name_pattern, position_pattern \\ nil) do
    with {:ok, parts} <- parse(String.trim(name_pattern || "")),
         :ok <- check_size(parts),
         {:ok, positions} <- positions(parts, position_pattern) do
      {:ok, Enum.zip(combinations(parts), positions)}
    end
  end

  # The default position is the slot token that ends each name (A1 in
  # DIMM A1), which is what compress/1 rebuilds; a name without one has no
  # position unless the pattern's brace groups give one.
  defp positions(parts, blank) when blank in [nil, ""] do
    choices = parts |> Enum.filter(&match?({:choices, _}, &1)) |> combinations()

    positions =
      parts
      |> combinations()
      |> Enum.zip(choices)
      |> Enum.map(fn {name, chosen} -> default_position(name, chosen) end)

    {:ok, positions}
  end

  defp positions(parts, position_pattern) do
    names = combinations(parts)

    with {:ok, positions} <- expand(position_pattern) do
      if length(positions) == length(names),
        do: {:ok, positions},
        else:
          {:error,
           "the position pattern gives #{length(positions)} positions for #{length(names)} names"}
    end
  end

  defp default_position(name, chosen) do
    case Regex.run(~r/[A-Za-z]?\d+$/, name) do
      [slot] -> slot
      nil when chosen == "" -> nil
      nil -> chosen
    end
  end

  defp check_size(parts) do
    count =
      Enum.reduce(parts, 1, fn
        {:choices, choices}, count -> count * length(choices)
        {:text, _text}, count -> count
      end)

    if count <= @max_names,
      do: :ok,
      else: {:error, "a pattern can make at most #{@max_names} templates, not #{count}"}
  end

  defp combinations(parts) do
    Enum.reduce(parts, [""], fn
      {:text, text}, names -> Enum.map(names, &(&1 <> text))
      {:choices, choices}, names -> for name <- names, choice <- choices, do: name <> choice
    end)
  end

  defp parse(""), do: {:error, "enter a name or pattern"}

  defp parse(pattern) do
    ~r/\{([^{}]*)\}|[^{}]+|[{}]/
    |> Regex.scan(pattern)
    |> Enum.reduce_while({:ok, []}, fn
      [_group, body], {:ok, parts} ->
        case choices(body) do
          {:ok, choices} -> {:cont, {:ok, [{:choices, choices} | parts]}}
          error -> {:halt, error}
        end

      [brace], _acc when brace in ["{", "}"] ->
        {:halt, {:error, "braces must come in pairs, like {A,B} or {1..16}"}}

      [text], {:ok, parts} ->
        {:cont, {:ok, [{:text, text} | parts]}}
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp choices(body) do
    case Regex.run(~r/^\s*(\d+)\s*\.\.\s*(\d+)\s*$/, body) do
      [_body, first, last] ->
        range(first, last)

      nil ->
        choices = body |> String.split(",") |> Enum.map(&String.trim/1)

        if Enum.any?(choices, &(&1 == "")),
          do: {:error, "{#{body}} has an empty choice"},
          else: {:ok, choices}
    end
  end

  defp range(first, last) do
    {from, to} = {String.to_integer(first), String.to_integer(last)}

    width =
      if String.starts_with?(first, "0") and byte_size(first) > 1, do: byte_size(first), else: 0

    if from <= to and to - from < @max_names do
      {:ok, Enum.map(from..to, &(&1 |> Integer.to_string() |> String.pad_leading(width, "0")))}
    else
      {:error, "{#{first}..#{last}} must count up"}
    end
  end

  @doc """
  Groups templates into patterns, ordered by kind and then as people count
  slots. Each `Group` lists the templates it stands for.
  """
  def compress(templates) do
    templates
    |> Enum.group_by(&{&1.kind, &1.required, &1.attributes, &1.label, &1.description})
    |> Enum.flat_map(fn {_shared, templates} -> compress_shared(templates) end)
    |> Enum.sort_by(&{&1.kind, natural_key(&1.name_pattern)})
  end

  # Templates sharing everything but name and position: split names into a
  # prefix and a trailing slot token, then merge letters whose numbers agree.
  defp compress_shared(templates) do
    {slotted, single} =
      templates
      |> Enum.map(&{&1, slot_parts(&1)})
      |> Enum.split_with(fn {_template, parts} -> parts end)

    singles =
      Enum.map(single, fn {template, nil} ->
        group([template], template.name, template.position)
      end)

    groups =
      slotted
      |> Enum.group_by(fn {_template, parts} ->
        {parts.prefix, parts.position_prefix, parts.width}
      end)
      |> Enum.flat_map(fn {key, members} -> bank_groups(key, members) end)

    singles ++ groups
  end

  # One prefix's slots: letters whose numbers agree share a pattern, so
  # A1-A16 and B1-B16 become {A,B}{1..16} while a short bank stays apart.
  defp bank_groups({prefix, position_prefix, width}, members) do
    members
    |> Enum.group_by(fn {_template, parts} -> parts.letter end, fn {template, parts} ->
      {parts.number, template}
    end)
    |> Enum.group_by(
      fn {_letter, numbered} -> numbered |> Enum.map(&elem(&1, 0)) |> Enum.sort() end,
      fn {letter, numbered} -> {letter, numbered} end
    )
    |> Enum.map(fn {numbers, lettered} ->
      letters = lettered |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      slot = choices_pattern(letters) <> numbers_pattern(numbers, width)

      templates =
        Enum.flat_map(lettered, fn {_letter, numbered} -> Enum.map(numbered, &elem(&1, 1)) end)

      position_pattern = if position_prefix == :none, do: nil, else: position_prefix <> slot

      group(templates, prefix <> slot, position_pattern)
    end)
  end

  # A name like "DIMM B12" splits into "DIMM ", "B", 12. Its position must
  # be the same slot token behind a common prefix ("B12" or "Slot B12") or
  # absent, so the group can rebuild it.
  defp slot_parts(%{name: name, position: position}) do
    with false <- String.contains?(name, ["{", "}"]),
         [_name, prefix, letter, digits] <- Regex.run(~r/^(.*?)([A-Za-z]?)(\d+)$/, name),
         {:ok, position_prefix} <- position_prefix(position, letter <> digits) do
      %{
        prefix: prefix,
        letter: letter,
        number: String.to_integer(digits),
        width:
          if(String.starts_with?(digits, "0") and byte_size(digits) > 1,
            do: byte_size(digits),
            else: 0
          ),
        position_prefix: position_prefix
      }
    else
      _irregular -> nil
    end
  end

  defp position_prefix(nil, _slot), do: {:ok, :none}

  defp position_prefix(position, slot) do
    if String.ends_with?(position, slot) and not String.contains?(position, ["{", "}"]),
      do: {:ok, String.replace_suffix(position, slot, "")},
      else: :error
  end

  defp choices_pattern([letter]), do: letter
  defp choices_pattern(letters), do: "{" <> Enum.join(letters, ",") <> "}"

  defp numbers_pattern([number], width), do: pad(number, width)

  defp numbers_pattern(numbers, width) do
    if Enum.to_list(List.first(numbers)..List.last(numbers)) == numbers,
      do: "{#{pad(List.first(numbers), width)}..#{pad(List.last(numbers), width)}}",
      else: "{" <> Enum.map_join(numbers, ",", &pad(&1, width)) <> "}"
  end

  defp pad(number, width), do: number |> Integer.to_string() |> String.pad_leading(width, "0")

  defp group([first | _rest] = templates, name_pattern, position_pattern) do
    %Group{
      kind: first.kind,
      name_pattern: name_pattern,
      position_pattern: position_pattern,
      label: first.label,
      description: first.description,
      required: first.required,
      attributes: first.attributes,
      templates: Enum.sort_by(templates, &natural_key(&1.name))
    }
  end

  @doc "Orders text as people count: DIMM A2 before DIMM A10."
  def natural_key(nil), do: []

  def natural_key(text) do
    ~r/\d+/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {number, ""} -> {0, number}
        _text -> {1, String.downcase(part)}
      end
    end)
  end
end
