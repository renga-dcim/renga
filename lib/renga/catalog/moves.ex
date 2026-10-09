defmodule Renga.Catalog.Moves do
  @moduledoc """
  Moving resources between revisions of their hardware type (RFD 8,
  "Editing hardware components"). Publishing a revision moves nothing;
  resources move one at a time from their Hardware tab or in bulk from the
  type's "Used by" list, and a type can move resources on its own once they
  fit its latest revision.

  A preview compares each resource with the target revision as it would be
  after the move, with its local changes carried over the way
  `Renga.Catalog.move_hardware_revision/3` carries them, and counts the
  differences it would open and close. A difference is observed drift,
  ambiguity, an unexpected part, or a required absence; satisfied local
  overrides and suppressed expectations are not differences.
  """
  import Ecto.Query

  alias Renga.Accounts.Scope
  alias Renga.Catalog
  alias Renga.Catalog.ActualComponent
  alias Renga.Catalog.ComponentTemplate
  alias Renga.Catalog.ConfirmedComponent
  alias Renga.Catalog.ExpectedComponent
  alias Renga.Catalog.ExpectedComponentException
  alias Renga.Catalog.HardwareAssignment
  alias Renga.Catalog.HardwareComparison
  alias Renga.Catalog.TypeRevision
  alias Renga.Repo

  @doc "The type's latest published revision, or nil."
  def latest_revision(%Scope{organization_id: organization_id}, hardware_type_id) do
    TypeRevision
    |> where([revision], revision.organization_id == ^organization_id)
    |> where([revision], revision.hardware_type_id == ^hardware_type_id)
    |> where([revision], not is_nil(revision.finalized_at))
    |> order_by([revision], desc: revision.revision)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Previews moving the resources using a hardware type to `revision` (or to
  templates not yet published, for a draft). Options: `:resource_ids` to
  limit the preview.

  Each entry has the `:resource`, its pinned `:revision` number,
  `:observed?` (whether a collector reported components for it), slot
  `:current` and `:target` counts, the differences the move would `:open`
  and `:close`, and how many local change records it would drop (`:dropped`)
  because the target has no template for them. `:conflicts` lists duplicate
  `{kind, name}` expectations that must be resolved before a move.
  """
  def preview(%Scope{} = scope, hardware_type_id, %TypeRevision{} = revision, opts \\ []) do
    templates =
      ComponentTemplate
      |> where([template], template.catalog_type_revision_id == ^revision.id)
      |> Repo.all()

    preview_templates(scope, hardware_type_id, templates, opts)
  end

  @doc false
  def preview_templates(
        %Scope{organization_id: organization_id},
        hardware_type_id,
        templates,
        opts
      ) do
    assignments =
      HardwareAssignment
      |> where([assignment], assignment.organization_id == ^organization_id)
      |> where([assignment], assignment.hardware_type_id == ^hardware_type_id)
      |> filter_resources(Keyword.get(opts, :resource_ids))
      |> preload([:resource, :catalog_type_revision])
      |> Repo.all()

    data = load(organization_id, assignments)

    assignments
    |> Enum.map(&entry(&1, templates, data))
    |> Enum.sort_by(&String.downcase(&1.resource.name))
  end

  @doc """
  Whether one assignment would have no differences at all on `revision`,
  with its local changes carried over: moving it can only close findings.
  """
  def fits?(
        %Scope{organization_id: organization_id},
        %HardwareAssignment{} = assignment,
        revision
      ) do
    templates =
      ComponentTemplate
      |> where([template], template.catalog_type_revision_id == ^revision.id)
      |> Repo.all()

    entry = entry(assignment, templates, load(organization_id, [assignment]))
    fits_entry?(entry)
  end

  @doc "Whether a preview entry would have no differences after the move."
  def fits_entry?(%{observed?: observed?, target: target, conflicts: conflicts}),
    do: observed? and conflicts == [] and differences(target) == 0

  @doc "The number of slots that differ in a set of counts."
  def differences(counts), do: counts.missing + counts.not_expected + counts.local_change

  @doc """
  Moves resources to `revision_id` together: all or none. Any catalog
  author may. Returns the number moved and the local changes dropped
  because the revision has no template for them.
  """
  def move(%Scope{} = scope, resource_ids, revision_id) do
    Catalog.author_transaction(scope, fn ->
      results =
        Enum.map(resource_ids, fn resource_id ->
          resource =
            Renga.Inventory.Resource
            |> where([resource], resource.organization_id == ^scope.organization_id)
            |> where([resource], resource.id == ^resource_id)
            |> lock("FOR UPDATE")
            |> Repo.one!()

          Catalog.move_assignment(scope, resource, revision_id)
        end)

      %{moved: length(results), dropped: Enum.flat_map(results, & &1.dropped)}
    end)
  end

  defp filter_resources(query, nil), do: query

  defp filter_resources(query, ids),
    do: where(query, [assignment], assignment.resource_id in ^ids)

  defp load(organization_id, assignments) do
    assignment_ids = Enum.map(assignments, & &1.id)
    resource_ids = Enum.map(assignments, & &1.resource_id)
    revision_ids = assignments |> Enum.map(& &1.catalog_type_revision_id) |> Enum.uniq()

    %{
      expected:
        grouped(ExpectedComponent, organization_id, :hardware_assignment_id, assignment_ids),
      exceptions:
        grouped(
          ExpectedComponentException,
          organization_id,
          :hardware_assignment_id,
          assignment_ids
        ),
      confirmations:
        grouped(ConfirmedComponent, organization_id, :hardware_assignment_id, assignment_ids),
      actuals: grouped(ActualComponent, organization_id, :owner_resource_id, resource_ids),
      pinned_templates:
        ComponentTemplate
        |> where([template], template.organization_id == ^organization_id)
        |> where([template], template.catalog_type_revision_id in ^revision_ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    }
  end

  defp grouped(schema, organization_id, field, ids) do
    schema
    |> where([row], row.organization_id == ^organization_id)
    |> where([row], field(row, ^field) in ^ids)
    |> Repo.all()
    |> Enum.group_by(&Map.fetch!(&1, field))
  end

  defp entry(assignment, templates, data) do
    actuals = Map.get(data.actuals, assignment.resource_id, [])
    exceptions = Map.get(data.exceptions, assignment.id, [])
    confirmations = Map.get(data.confirmations, assignment.id, [])

    template_map = template_map(data.pinned_templates, templates)
    target_expected = target_expectations(assignment, templates, exceptions, template_map)

    dropped_exceptions =
      Enum.filter(exceptions, fn exception ->
        exception.component_template_id &&
          not Map.has_key?(template_map, exception.component_template_id)
      end)

    dropped_exception_ids = MapSet.new(dropped_exceptions, & &1.id)

    current_rows =
      rows(
        Map.get(data.expected, assignment.id, []),
        actuals,
        confirmation_index(confirmations, & &1)
      )

    target_rows =
      rows(
        target_expected,
        actuals,
        confirmation_index(confirmations, &Map.get(template_map, &1))
      )

    current = difference_keys(current_rows)
    target = difference_keys(target_rows)

    %{
      resource: assignment.resource,
      assignment: assignment,
      revision: assignment.catalog_type_revision.revision,
      observed?: actuals != [],
      current: counts(current_rows),
      target: counts(target_rows),
      open: MapSet.size(MapSet.difference(target, current)),
      close: MapSet.size(MapSet.difference(current, target)),
      conflicts:
        target_expected
        |> Enum.frequencies_by(&{&1.kind, &1.name})
        |> Enum.filter(fn {_identity, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort(),
      dropped:
        length(dropped_exceptions) +
          Enum.count(confirmations, fn record ->
            if record.component_template_id,
              do: not Map.has_key?(template_map, record.component_template_id),
              else: MapSet.member?(dropped_exception_ids, record.exception_id)
          end)
    }
  end

  # The pinned revision's template ids matched to the target's by kind and
  # name, as a move carries them.
  defp template_map(pinned_templates, targets) do
    by_identity = Map.new(targets, &{Catalog.template_identity(&1), &1.id})

    pinned_templates
    |> Enum.flat_map(fn {id, template} ->
      case Map.fetch(by_identity, Catalog.template_identity(template)) do
        {:ok, target_id} -> [{id, target_id}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  # What the resource would expect on the target: its templates with the
  # carried exceptions applied, plus the parts only it expects.
  defp target_expectations(assignment, templates, exceptions, template_map) do
    carried =
      exceptions
      |> Enum.filter(& &1.component_template_id)
      |> Enum.flat_map(fn exception ->
        case Map.fetch(template_map, exception.component_template_id) do
          {:ok, target_id} -> [{target_id, exception}]
          :error -> []
        end
      end)
      |> Map.new()

    from_templates =
      Enum.map(templates, fn template ->
        exception = Map.get(carried, template.id)

        template
        |> Catalog.template_expectation_attrs(exception)
        |> expectation(assignment, template.id, exception && exception.id)
      end)

    added =
      exceptions
      |> Enum.filter(&(&1.action == "add"))
      |> Enum.map(fn exception ->
        exception
        |> Catalog.added_expectation_attrs()
        |> expectation(assignment, nil, exception.id)
      end)

    from_templates ++ added
  end

  defp expectation(attrs, assignment, template_id, exception_id) do
    %ExpectedComponent{
      kind: attrs["kind"],
      name: attrs["name"],
      label: attrs["label"],
      position: attrs["position"],
      description: attrs["description"],
      required: Map.get(attrs, "required", true),
      suppressed: Map.get(attrs, "suppressed", false),
      attributes: attrs["attributes"] || %{},
      hardware_assignment_id: assignment.id,
      component_template_id: template_id,
      exception_id: exception_id
    }
  end

  # Confirmations keyed as Catalog.confirmations_by_expectation/2 keys
  # them, with template ids translated by `map_template`.
  defp confirmation_index(confirmations, map_template) do
    Enum.flat_map(confirmations, fn
      %{component_template_id: nil, exception_id: id} = confirmation ->
        [{{:exception, id}, confirmation}]

      %{component_template_id: id} = confirmation ->
        case map_template.(id) do
          nil -> []
          target_id -> [{{:template, target_id}, confirmation}]
        end
    end)
    |> Map.new()
  end

  defp rows(expected, actuals, confirmations) do
    comparison = HardwareComparison.build(expected, actuals, confirmations)
    for section <- comparison.sections, row <- section.rows, do: row
  end

  defp difference_keys(rows) do
    rows
    |> Enum.filter(&difference?/1)
    |> MapSet.new(&{&1.kind, String.downcase(&1.label)})
  end

  defp difference?(%{state: :match}), do: false
  defp difference?(%{state: :missing, expected: %{required: false}}), do: false

  defp difference?(%{state: :local_change, reasons: reasons}),
    do: Enum.any?(reasons, &(&1 in [:drift, :ambiguous, :replacement_pending]))

  defp difference?(_row), do: true

  # An optional slot left empty is counted apart: no finding opens for it.
  defp counts(rows) do
    Enum.reduce(
      rows,
      %{match: 0, missing: 0, not_expected: 0, local_change: 0, empty: 0},
      fn
        %{state: :missing, expected: %{required: false}}, counts ->
          Map.update!(counts, :empty, &(&1 + 1))

        %{state: :local_change} = row, counts ->
          state = if difference?(row), do: :local_change, else: :match
          Map.update!(counts, state, &(&1 + 1))

        %{state: state}, counts ->
          Map.update!(counts, state, &(&1 + 1))
      end
    )
  end
end
