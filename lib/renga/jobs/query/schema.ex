defmodule Renga.Jobs.Query.Schema do
  @moduledoc """
  The small type language a query capability declares its parameters and
  result in (RFD 12).

  A schema is plain data, so one declaration validates a request before the
  job is stored, validates the agent's result before it is recorded, and
  lets the interface render a form and a table without knowing the query.
  The agent validates the same shapes again with its own types.

  Types:

    * `:string` or `{:string, max: n}` (at most 1024 characters by default)
    * `:integer` or `{:integer, min: a, max: b}`
    * `:boolean`
    * `{:enum, values}` - one of a list of strings
    * `{:list, type, max: n}` - a list of at most `n` items; `max` is required
      so no result is unbounded
    * `{:object, fields}` - a map with exactly the string keys `fields` lists
      as `{name, type}` pairs, in the order people should see them
    * `{:nullable, type}` - the type, or `null`

  A field in an object is required unless declared `{:optional, type}`.
  Unknown fields are rejected everywhere.
  """

  import Ecto.Changeset

  @default_string_max 1024

  @doc """
  Validates `value` against an object schema and returns a schemaless
  changeset, the shape `Renga.Jobs.Capability` callbacks return. Errors are
  keyed by top-level field, with nested paths in the message.
  """
  def changeset({:object, fields} = schema, value) when is_map(value) do
    present =
      for {name, _type} <- fields, Map.has_key?(value, name), into: %{} do
        {atom(name), Map.fetch!(value, name)}
      end

    schema
    |> validate(value)
    |> Enum.reduce(change({%{}, types(fields)}, present), fn {path, message}, changeset ->
      add_path_error(changeset, path, message)
    end)
  end

  def changeset({:object, fields}, _value),
    do: {%{}, types(fields)} |> change() |> add_error(:base, "must be an object")

  defp types(fields), do: Map.new(fields, fn {name, _type} -> {atom(name), :any} end)

  # Field names come from schemas declared in code, never from a request:
  # an unknown field is an error before any name becomes an atom.
  defp atom(name), do: String.to_atom(name)

  defp add_path_error(changeset, [], message), do: add_error(changeset, :base, message)

  defp add_path_error(changeset, [field], message) when is_binary(field) do
    if known_field?(changeset, field),
      do: add_error(changeset, atom(field), message),
      else: add_error(changeset, :base, "#{field} #{message}")
  end

  defp add_path_error(changeset, [field | rest], message) do
    add_error(changeset, atom(field), "#{Enum.map_join(rest, "", &segment/1)} #{message}")
  end

  defp known_field?(%Ecto.Changeset{types: types}, field),
    do: Enum.any?(Map.keys(types), &(Atom.to_string(&1) == field))

  defp segment(index) when is_integer(index), do: "[#{index}]"
  defp segment(name), do: ".#{name}"

  @doc """
  Validates `value` against `schema`, returning `{path, message}` errors in
  document order. An empty list means it conforms.
  """
  def validate(schema, value), do: validate(schema, value, [])

  defp validate({:nullable, _type}, nil, _path), do: []
  defp validate({:nullable, type}, value, path), do: validate(type, value, path)

  defp validate(:string, value, path), do: validate({:string, []}, value, path)

  defp validate({:string, opts}, value, path) when is_binary(value) do
    max = Keyword.get(opts, :max, @default_string_max)

    cond do
      not String.valid?(value) -> [{path, "must be valid UTF-8"}]
      String.length(value) > max -> [{path, "must be at most #{max} characters"}]
      true -> []
    end
  end

  defp validate(:integer, value, path), do: validate({:integer, []}, value, path)

  defp validate({:integer, opts}, value, path) when is_integer(value) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      min && value < min -> [{path, "must be at least #{min}"}]
      max && value > max -> [{path, "must be at most #{max}"}]
      true -> []
    end
  end

  defp validate(:boolean, value, _path) when is_boolean(value), do: []

  defp validate({:enum, values}, value, path) when is_binary(value) do
    if value in values, do: [], else: [{path, "must be one of #{Enum.join(values, ", ")}"}]
  end

  defp validate({:list, type, opts}, value, path) when is_list(value) do
    max = Keyword.fetch!(opts, :max)

    if length(value) > max do
      [{path, "must have at most #{max} items"}]
    else
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} -> validate(type, item, path ++ [index]) end)
    end
  end

  defp validate({:object, fields}, value, path) when is_map(value) do
    names = Enum.map(fields, &elem(&1, 0))

    unknown =
      for name <- value |> Map.keys() |> Enum.sort(),
          name not in names,
          do: {path ++ [name], "is not a known field"}

    known =
      Enum.flat_map(fields, fn
        {name, {:optional, type}} ->
          if Map.has_key?(value, name),
            do: validate(type, Map.fetch!(value, name), path ++ [name]),
            else: []

        {name, type} ->
          if Map.has_key?(value, name),
            do: validate(type, Map.fetch!(value, name), path ++ [name]),
            else: [{path ++ [name], "can't be blank"}]
      end)

    unknown ++ known
  end

  defp validate(type, _value, path), do: [{path, "must be #{describe(type)}"}]

  defp describe({:string, _opts}), do: "a string"
  defp describe({:integer, _opts}), do: "an integer"
  defp describe(:boolean), do: "true or false"
  defp describe({:enum, _values}), do: "a string"
  defp describe({:list, _type, _opts}), do: "a list"
  defp describe({:object, _fields}), do: "an object"

  @doc """
  The fields of an object schema in declared order, each as
  `{name, type, required?}`, for rendering forms and tables.
  """
  def fields({:object, fields}) do
    Enum.map(fields, fn
      {name, {:optional, type}} -> {name, type, false}
      {name, type} -> {name, type, true}
    end)
  end
end
