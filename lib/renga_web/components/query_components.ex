defmodule RengaWeb.QueryComponents do
  @moduledoc """
  Pieces that show operational queries (RFD 12) the same way on a host's
  Queries tab and on a batch's results: a parameters form and a result
  built from the query's schema, so a new query needs no new interface.
  """
  use Phoenix.Component

  import RengaUI.CoreComponents, only: [input: 1]

  alias Renga.Jobs.Job
  alias Renga.Jobs.Query
  alias Renga.Jobs.Query.Schema
  alias RengaWeb.Format

  @doc "An empty or submitted parameters form, with the schema's errors."
  def parameters_form(values, errors \\ []), do: to_form(values, as: :query, errors: errors)

  @doc """
  A query's parameter inputs, one per schema field: integers as numbers with
  their bounds, booleans as checkboxes, enums as selects, and strings as text.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :module, :atom, required: true

  def parameter_fields(assigns) do
    assigns = assign(assigns, :fields, Query.parameter_fields(assigns.module))

    ~H"""
    <%!-- Names come from the query's own schema, so the atoms are bounded;
          they may not exist yet on a fresh node. --%>
    <div :for={{name, type, required?} <- @fields}>
      <.parameter_input
        field={@form[String.to_atom(name)]}
        type={unwrap(type)}
        required?={required?}
      />
    </div>
    <p :if={@fields == []} class="text-sm text-fg-muted">It takes no parameters.</p>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :any, required: true
  attr :required?, :boolean, required: true

  defp parameter_input(%{type: {:integer, opts}} = assigns) do
    assigns = assign(assigns, min: opts[:min], max: opts[:max])

    ~H"""
    <.input
      field={@field}
      type="number"
      label={label(@field.field)}
      min={@min}
      max={@max}
      placeholder={unless @required?, do: "Any"}
    />
    """
  end

  defp parameter_input(%{type: :integer} = assigns),
    do: parameter_input(%{assigns | type: {:integer, []}})

  defp parameter_input(%{type: :boolean} = assigns) do
    ~H"""
    <.input field={@field} type="checkbox" label={label(@field.field)} />
    """
  end

  defp parameter_input(%{type: {:enum, values}} = assigns) do
    assigns = assign(assigns, :values, values)

    ~H"""
    <.input
      field={@field}
      type="select"
      label={label(@field.field)}
      prompt={unless @required?, do: "Any"}
      options={@values}
    />
    """
  end

  defp parameter_input(assigns) do
    ~H"""
    <.input
      field={@field}
      type="text"
      label={label(@field.field)}
      placeholder={unless @required?, do: "Any"}
      autocomplete="off"
    />
    """
  end

  @doc """
  The parameters a submitted form asks for. The form sends strings; the
  schema wants integers and booleans. A blank optional field is left out,
  and a value that does not parse is passed through for the schema to refuse.
  """
  def form_parameters(module, values) do
    for {name, type, _required?} <- Query.parameter_fields(module),
        value = Map.get(values, name),
        value not in [nil, ""],
        into: %{} do
      {name, typed(unwrap(type), value)}
    end
  end

  defp typed({:integer, _opts}, value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp typed(:integer, value), do: typed({:integer, []}, value)
  defp typed(:boolean, value), do: value == "true"
  defp typed(_type, value), do: value

  defp unwrap({:nullable, type}), do: type
  defp unwrap(type), do: type

  @acronyms %{"fs" => "FS", "pid" => "PID", "sql" => "SQL", "vrf" => "VRF"}

  @doc """
  A field's name as a label: `fs_type` reads "FS type", and a unit the value
  already shows (`size_bytes`, `offset_us`) is left off. An osquery SQL
  column names itself, so it can be blank or nothing but a unit.
  """
  def label(field) do
    name = to_string(field)
    stripped = String.replace(name, ~r/_(bytes|us)$/, "")

    case stripped
         |> then(&if(&1 == "", do: name, else: &1))
         |> String.split("_")
         |> Enum.map_join(" ", &Map.get(@acronyms, &1, &1)) do
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
      "" -> ""
    end
  end

  @doc """
  A succeeded run's result, split the way its schema reads: lists of
  objects, and an osquery SQL result's `columns` and `rows`, as tables
  (`%{name, columns, rows}`), other fields as `{name, value}` properties,
  and `truncated` as a flag. Nil for any other run, or one whose payload is
  withheld.
  """
  def result_parts(module, %Job{state: "succeeded", payload_hidden: false, result: %{} = result}) do
    {:object, _fields} = schema = module.result_schema()

    Enum.reduce(Schema.fields(schema), %{scalars: [], lists: [], truncated?: false}, fn
      {"truncated", :boolean, _required?}, parts ->
        %{parts | truncated?: result["truncated"] == true}

      {name, {:list, {:object, _} = item, _opts}, _required?}, parts ->
        list = %{name: name, columns: Schema.fields(item), rows: result[name] || []}
        %{parts | lists: parts.lists ++ [list]}

      # A table of strings (`query.sql@1`): `columns` names each row's cells
      # in order, so the two read as one table rather than as two fields.
      {"columns", {:list, _item, _opts}, _required?}, parts ->
        parts

      {name, {:list, {:list, _cell, _cell_opts}, _opts}, _required?}, parts ->
        names = result["columns"] || []
        rows = for row <- result[name] || [], do: Map.new(Enum.zip(names, row))

        list = %{
          name: name,
          columns: for(column <- names, do: {column, :string, true}),
          rows: rows
        }

        %{parts | lists: parts.lists ++ [list]}

      {name, _type, _required?}, parts ->
        %{parts | scalars: parts.scalars ++ [{name, result[name]}]}
    end)
  end

  def result_parts(_module, _job), do: nil

  @doc """
  What a run asked, in the order its schema declares: `port 22, failed
  only`. Nil when its parameters are withheld or it asked nothing.
  """
  def asked(%Job{payload_hidden: true}), do: nil

  def asked(%Job{parameters: parameters} = job) when map_size(parameters) > 0 do
    with module when not is_nil(module) <- Query.module_for(Job.capability_key(job)),
         [_ | _] = terms <-
           for(
             {name, _type, _required?} <- Query.parameter_fields(module),
             term = asked_term(name, Map.get(parameters, name)),
             do: term
           ) do
      Enum.join(terms, ", ")
    else
      _nothing -> nil
    end
  end

  def asked(%Job{}), do: nil

  defp asked_term(_name, nil), do: nil
  defp asked_term(_name, false), do: nil
  defp asked_term(name, true), do: Format.humanize(name)
  defp asked_term(name, value), do: "#{Format.humanize(name)} #{value}"

  @doc "A result value as people read it, with units its field name implies."
  def format_value(_name, nil), do: "—"
  def format_value(_name, true), do: "Yes"
  def format_value(_name, false), do: "No"

  def format_value(name, value) when is_integer(value) do
    cond do
      String.ends_with?(name, "_bytes") -> bytes(value)
      String.ends_with?(name, "_us") -> "#{value} µs"
      true -> Integer.to_string(value)
    end
  end

  def format_value(_name, value), do: to_string(value)

  @doc "Classes for a result value's cell: numbers align, absent values recede."
  def value_class(value) when is_integer(value), do: "font-mono tabular-nums"
  def value_class(nil), do: "text-fg-subtle"
  def value_class(_value), do: nil

  defp bytes(value) when value < 1024, do: "#{value} B"
  defp bytes(value), do: bytes(value / 1024, ~w(KiB MiB GiB TiB PiB))

  defp bytes(size, [_unit | [_ | _] = larger]) when size >= 1024, do: bytes(size / 1024, larger)
  defp bytes(size, [unit | _larger]), do: "#{:erlang.float_to_binary(size, decimals: 1)} #{unit}"

  @doc "A query's sensitivity as people read it."
  def sensitivity_label(:inventory), do: "Inventory"
  def sensitivity_label(:sensitive), do: "Sensitive"
end
