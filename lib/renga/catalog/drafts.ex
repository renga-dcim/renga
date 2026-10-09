defmodule Renga.Catalog.Drafts do
  @moduledoc """
  Draft revisions of a hardware type (RFD 8, "Editing hardware components").

  Editing a type starts a draft: an unpublished revision copied from the
  latest published one. A draft changes freely, saved as it is edited, and
  each type has at most one. Templates are edited in groups through name
  patterns (`Renga.Catalog.TemplatePattern`). Before publishing, the change
  list shows what differs from the latest published revision and the impact
  shows how the resources using the type would compare with the draft.

  Publishing freezes the draft as the type's newest revision. It never
  moves a resource: each stays pinned to its revision until it is moved.
  """
  import Ecto.Query

  alias Renga.Accounts.Scope
  alias Renga.Catalog
  alias Renga.Catalog.ActualComponent
  alias Renga.Catalog.ComponentTemplate
  alias Renga.Catalog.ExpectedComponent
  alias Renga.Catalog.HardwareAssignment
  alias Renga.Catalog.HardwareComparison
  alias Renga.Catalog.HardwareType
  alias Renga.Catalog.TemplatePattern
  alias Renga.Catalog.TypeRevision
  alias Renga.Repo

  @revision_fields ~w(part_number height_units width_mm depth_mm weight_kg airflow specifications)a
  @template_fields ~w(position label description required attributes)a

  @doc "The fields of a revision a draft can change, in display order."
  def revision_fields, do: @revision_fields

  @doc "The type's draft with its templates, or nil."
  def get_draft(%Scope{organization_id: organization_id}, %HardwareType{id: type_id}) do
    TypeRevision
    |> where([revision], revision.organization_id == ^organization_id)
    |> where([revision], revision.hardware_type_id == ^type_id and is_nil(revision.finalized_at))
    |> Repo.one()
    |> preload_templates()
  end

  @doc """
  The type's latest published revision with its templates, or nil. A
  draft starts from it and is compared with it.
  """
  def base_revision(%Scope{organization_id: organization_id}, %HardwareType{id: type_id}) do
    TypeRevision
    |> where([revision], revision.organization_id == ^organization_id)
    |> where(
      [revision],
      revision.hardware_type_id == ^type_id and not is_nil(revision.finalized_at)
    )
    |> order_by([revision], desc: revision.revision)
    |> limit(1)
    |> Repo.one()
    |> preload_templates()
  end

  @doc """
  Starts a draft copied from the latest published revision, or returns the
  draft already open. Any catalog author may.
  """
  def start_draft(%Scope{} = scope, %HardwareType{} = hardware_type) do
    Catalog.author_transaction(scope, fn ->
      type = lock_type!(scope, hardware_type)

      case get_draft(scope, type) do
        %TypeRevision{} = draft -> draft
        nil -> create_draft(scope, type)
      end
    end)
  end

  defp create_draft(scope, type) do
    base = base_revision(scope, type)
    copied = if base, do: Map.take(base, @revision_fields), else: %{specifications: %{}}

    draft =
      %TypeRevision{
        organization_id: scope.organization_id,
        hardware_type_id: type.id,
        revision: next_revision(scope.organization_id, type.id)
      }
      |> Ecto.Changeset.change(copied)
      |> Repo.insert!()

    for template <- (base && base.component_templates) || [] do
      %ComponentTemplate{
        organization_id: scope.organization_id,
        catalog_type_revision_id: draft.id
      }
      |> ComponentTemplate.draft_changeset(
        template
        |> Map.take([:kind, :name | @template_fields])
        |> stringify()
      )
      |> Repo.insert!()
    end

    preload_templates(draft)
  end

  @doc "Saves revision fields on a draft."
  def update_draft(%Scope{} = scope, %TypeRevision{} = draft, attrs) do
    Catalog.author_transaction(scope, fn ->
      scope
      |> lock_draft!(draft)
      |> TypeRevision.draft_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, draft} -> preload_templates(draft)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Replaces the templates `replacing` (ids, empty for a new group) with the
  templates a group's patterns expand to.

  `attrs` carries `"kind"`, `"name_pattern"`, an optional
  `"position_pattern"`, `"required"`, `"label"`, `"description"`, and an
  `"attributes"` map. Returns `{:error, message}` when a pattern does not
  expand or names a template another group already has.
  """
  def put_template_group(%Scope{} = scope, %TypeRevision{} = draft, replacing, attrs) do
    case TemplatePattern.expand_slots(attrs["name_pattern"], attrs["position_pattern"]) do
      {:ok, slots} ->
        Catalog.author_transaction(scope, fn ->
          draft = lock_draft!(scope, draft)
          replace_templates(scope, draft, List.wrap(replacing), slots, attrs)
        end)

      {:error, message} ->
        {:error, message}
    end
  end

  defp replace_templates(scope, draft, replacing, slots, attrs) do
    kind = attrs["kind"]
    names = MapSet.new(slots, fn {name, _position} -> String.downcase(name) end)

    taken =
      draft_templates(draft)
      |> Enum.reject(&(&1.id in replacing))
      |> Enum.find(&(&1.kind == kind and MapSet.member?(names, String.downcase(&1.name))))

    if taken, do: Repo.rollback("#{taken.name} is already a template in another group")

    ComponentTemplate
    |> where([template], template.catalog_type_revision_id == ^draft.id)
    |> where([template], template.id in ^replacing)
    |> Repo.delete_all()

    for {name, position} <- slots do
      %ComponentTemplate{
        organization_id: scope.organization_id,
        catalog_type_revision_id: draft.id
      }
      |> ComponentTemplate.draft_changeset(
        attrs
        |> Map.take(~w(kind label description required attributes))
        |> Map.merge(%{"name" => name, "position" => position})
      )
      |> Repo.insert()
      |> case do
        {:ok, template} -> template
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end

    preload_templates(draft)
  end

  @doc "Removes templates from a draft."
  def delete_templates(%Scope{} = scope, %TypeRevision{} = draft, ids) do
    Catalog.author_transaction(scope, fn ->
      draft = lock_draft!(scope, draft)

      ComponentTemplate
      |> where([template], template.catalog_type_revision_id == ^draft.id)
      |> where([template], template.id in ^List.wrap(ids))
      |> Repo.delete_all()

      preload_templates(draft)
    end)
  end

  @doc "Discards a draft and its templates."
  def discard_draft(%Scope{} = scope, %TypeRevision{} = draft) do
    Catalog.author_transaction(scope, fn ->
      draft = lock_draft!(scope, draft)

      ComponentTemplate
      |> where([template], template.catalog_type_revision_id == ^draft.id)
      |> Repo.delete_all()

      Repo.delete!(draft)
      :discarded
    end)
  end

  @doc """
  Publishes a draft as the type's newest revision. No resource moves; each
  stays pinned to its revision until it is moved.
  """
  def publish_draft(%Scope{} = scope, %TypeRevision{} = draft) do
    Catalog.author_transaction(scope, fn ->
      draft = lock_draft!(scope, draft)

      {1, _rows} =
        TypeRevision
        |> where([revision], revision.id == ^draft.id and is_nil(revision.finalized_at))
        |> Repo.update_all(set: [finalized_at: Renga.Time.utc_now_ms()])

      TypeRevision |> Repo.get!(draft.id) |> preload_templates()
    end)
  end

  @doc """
  What a draft changes from the latest published revision: revision fields
  and specifications as `{field, before, after}`, and templates added,
  removed, and changed, each as pattern groups. Changed groups list the
  fields that differ.
  """
  def change_list(%Scope{} = scope, %TypeRevision{} = draft) do
    base = base_revision(scope, %HardwareType{id: draft.hardware_type_id})
    before = (base && base.component_templates) || []
    keyed_before = Map.new(before, &{template_key(&1), &1})
    keyed_after = Map.new(draft.component_templates, &{template_key(&1), &1})

    changed =
      draft.component_templates
      |> Enum.filter(fn template ->
        case Map.fetch(keyed_before, template_key(template)) do
          {:ok, old} -> Map.take(old, @template_fields) != Map.take(template, @template_fields)
          :error -> false
        end
      end)

    %{
      base: base,
      fields:
        Enum.flat_map(@revision_fields -- [:specifications], fn field ->
          old = if base, do: Map.get(base, field), else: nil
          new = Map.get(draft, field)
          if same_field?(old, new), do: [], else: [{field, old, new}]
        end),
      specifications:
        specification_changes((base && base.specifications) || %{}, draft.specifications),
      added:
        draft.component_templates
        |> Enum.reject(&Map.has_key?(keyed_before, template_key(&1)))
        |> TemplatePattern.compress(),
      removed:
        before
        |> Enum.reject(&Map.has_key?(keyed_after, template_key(&1)))
        |> TemplatePattern.compress(),
      changed:
        changed
        |> TemplatePattern.compress()
        |> Enum.map(fn group ->
          old = Map.fetch!(keyed_before, template_key(hd(group.templates)))

          fields =
            Enum.reject(@template_fields, &(Map.get(old, &1) == Map.get(hd(group.templates), &1)))

          {group, fields}
        end)
    }
  end

  # Specifications are compared key by key so the review names each fact
  # that changed rather than the whole map.
  defp specification_changes(old, new) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      {was, now} = {Map.get(old, key), Map.get(new, key)}
      if same_field?(was, now), do: [], else: [{key, was, now}]
    end)
  end

  defp same_field?(%Decimal{} = old, %Decimal{} = new), do: Decimal.equal?(old, new)
  defp same_field?(old, new), do: old == new

  @doc """
  How the resources using the type compare with the draft, next to how
  they compare with the revision they are pinned to. Each entry has the
  resource, its pinned revision number, and slot counts for `:current`
  and `:draft`: `HardwareComparison` counts, with optional slots left
  empty counted as `:empty` rather than missing. `observed?`
  is false for resources no collector has reported components for, whose
  slots would all read as missing.
  """
  def impact(%Scope{organization_id: organization_id}, %TypeRevision{} = draft) do
    assignments =
      HardwareAssignment
      |> where([assignment], assignment.organization_id == ^organization_id)
      |> where([assignment], assignment.hardware_type_id == ^draft.hardware_type_id)
      |> preload([:resource, :catalog_type_revision])
      |> Repo.all()

    assignment_ids = Enum.map(assignments, & &1.id)
    resource_ids = Enum.map(assignments, & &1.resource_id)

    current =
      ExpectedComponent
      |> where([expected], expected.organization_id == ^organization_id)
      |> where([expected], expected.hardware_assignment_id in ^assignment_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.hardware_assignment_id)

    actuals =
      ActualComponent
      |> where([actual], actual.organization_id == ^organization_id)
      |> where([actual], actual.owner_resource_id in ^resource_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.owner_resource_id)

    assignments
    |> Enum.map(fn assignment ->
      observed = Map.get(actuals, assignment.resource_id, [])
      drafted = Enum.map(draft.component_templates, &draft_expectation(&1, assignment))

      %{
        resource: assignment.resource,
        revision: assignment.catalog_type_revision.revision,
        observed?: observed != [],
        current: counts(Map.get(current, assignment.id, []), observed),
        draft: counts(drafted, observed)
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.resource.name))
  end

  @doc "Whether an impact entry would have no differences on the draft."
  def fits?(%{observed?: observed?, draft: draft}),
    do: observed? and draft.missing + draft.not_expected + draft.local_change == 0

  # An optional slot left empty is not a difference: no finding opens for it.
  defp counts(expected, observed) do
    rows =
      for section <- HardwareComparison.build(expected, observed).sections,
          row <- section.rows,
          do: row

    Enum.reduce(
      rows,
      %{match: 0, missing: 0, not_expected: 0, local_change: 0, empty: 0},
      fn
        %{state: :missing, expected: %{required: false}}, counts ->
          Map.update!(counts, :empty, &(&1 + 1))

        %{state: state}, counts ->
          Map.update!(counts, state, &(&1 + 1))
      end
    )
  end

  # What a resource would expect from a draft template, before any of its
  # own exceptions, which belong to the revision it is pinned to.
  defp draft_expectation(template, assignment) do
    %ExpectedComponent{
      kind: template.kind,
      name: template.name,
      label: template.label,
      position: template.position,
      required: template.required,
      suppressed: false,
      attributes: template.attributes,
      component_template_id: template.id,
      exception_id: nil,
      hardware_assignment_id: assignment.id
    }
  end

  defp template_key(template), do: {template.kind, String.downcase(template.name)}

  defp draft_templates(draft) do
    ComponentTemplate
    |> where([template], template.catalog_type_revision_id == ^draft.id)
    |> Repo.all()
  end

  defp lock_type!(scope, %HardwareType{id: id}) do
    HardwareType
    |> where([type], type.organization_id == ^scope.organization_id and type.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  # A draft published or discarded elsewhere is gone, not an error to crash on.
  defp lock_draft!(scope, %TypeRevision{id: id}) do
    TypeRevision
    |> where([revision], revision.organization_id == ^scope.organization_id)
    |> where([revision], revision.id == ^id and is_nil(revision.finalized_at))
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:draft_closed)
      draft -> draft
    end
  end

  defp next_revision(organization_id, type_id) do
    TypeRevision
    |> where([revision], revision.organization_id == ^organization_id)
    |> where([revision], revision.hardware_type_id == ^type_id)
    |> select([revision], coalesce(max(revision.revision), 0) + 1)
    |> Repo.one()
  end

  defp preload_templates(nil), do: nil

  defp preload_templates(revision) do
    Repo.preload(
      revision,
      [component_templates: from(template in ComponentTemplate, order_by: template.name)],
      force: true
    )
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
