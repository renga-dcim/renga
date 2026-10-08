defmodule Renga.Triage do
  @moduledoc """
  Triage (RFD 8): resources missing facts a person usually supplies.

  Triage is computed, never stored. A resource is in triage while it lacks
  any of:

    * `:placement` - no current placement (site, location, or rack);
    * `:hardware_type` - a physical device with no catalog hardware type;
    * `:owner` - no owning team;
    * `:identity` - reconciliation could not tell it apart from another
      resource: the latest attempt for some observation failed as ambiguous
      with this resource among the candidates.

  It leaves triage on its own when the fact arrives, from a person, a rule,
  or a collector, because nothing marks it as triaged. Triage never hides
  anything: untriaged resources still appear in every list and count.

  Only physical devices enter triage. Virtual machines and other
  short-lived or logical resources never do; retired resources neither.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Catalog.HardwareAssignment
  alias Renga.DCIM.CurrentPlacement
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Resource
  alias Renga.Repo

  @facts [:placement, :hardware_type, :owner, :identity]
  @triage_kinds ~w(server switch pdu storage unknown)
  # Catalog hardware types exist only for these kinds (RFD 6).
  @typed_kinds ~w(server switch pdu storage)
  @per_page 50

  @doc "The facts triage asks for, in display order."
  def facts, do: @facts

  @doc "Resource kinds that can be in triage."
  def kinds, do: @triage_kinds

  @doc "Page size used by `list_triage/2`."
  def per_page, do: @per_page

  @doc """
  Resources in triage, most recently created first. Each entry is
  `%{resource: resource, missing: [fact]}`.

  Options: `:missing` (one fact), `:page`. Returns `{entries, total}`.
  """
  def list_triage(%Scope{} = scope, opts \\ []) do
    query = triage_query(scope, Keyword.get(opts, :missing))
    page = max(Keyword.get(opts, :page, 1), 1)

    entries =
      query
      |> order_by([row], desc: row.inserted_at, asc: row.id)
      |> limit(@per_page)
      |> offset(^((page - 1) * @per_page))
      |> Repo.all()
      |> to_entries(scope)

    {entries, Repo.aggregate(query, :count)}
  end

  @doc "How many resources lack each fact, and how many are in triage at all."
  def counts(%Scope{} = scope) do
    row =
      scope
      |> flagged_query()
      |> subquery()
      |> where([row], ^any_missing())
      |> select([row], %{
        total: count(),
        placement: filter(count(), not row.placed),
        hardware_type: filter(count(), not row.typed),
        owner: filter(count(), not row.owned),
        identity: filter(count(), row.ambiguous)
      })
      |> Repo.one()

    row
  end

  @doc "The facts one resource is missing, or `[]` when it is not in triage."
  def missing(%Scope{} = scope, %Resource{} = resource) do
    scope
    |> flagged_query()
    |> where([resource], resource.id == ^resource.id)
    |> Repo.one()
    |> case do
      nil -> []
      row -> missing_facts(row)
    end
  end

  @doc """
  Other resources reconciliation could not tell apart from this one, from
  the latest ambiguous attempts that named it.
  """
  def identity_candidates(%Scope{organization_id: organization_id} = scope, %Resource{id: id}) do
    ids =
      scope
      |> ambiguous_attempts()
      |> where([attempt], fragment("? -> 'candidate_resource_ids' \\? ?", attempt.errors, ^id))
      |> select([attempt], attempt.errors)
      |> Repo.all()
      |> Enum.flat_map(&Map.get(&1, "candidate_resource_ids", []))
      |> Enum.uniq()
      |> List.delete(id)

    Resource
    |> where([resource], resource.organization_id == ^organization_id and resource.id in ^ids)
    |> order_by([resource], asc: resource.name)
    |> Repo.all()
  end

  @doc false
  # Ids of resources in triage that lack `fact`, for queries that group or
  # count them (`Renga.Triage.Patterns`).
  def missing_ids_query(%Scope{} = scope, fact) when fact in @facts do
    scope
    |> triage_query(fact)
    |> select([row], row.id)
  end

  defp triage_query(scope, missing) do
    scope
    |> flagged_query()
    |> subquery()
    |> where([row], ^any_missing())
    |> filter_missing(missing)
  end

  defp filter_missing(query, :placement), do: where(query, [row], not row.placed)
  defp filter_missing(query, :hardware_type), do: where(query, [row], not row.typed)
  defp filter_missing(query, :owner), do: where(query, [row], not row.owned)
  defp filter_missing(query, :identity), do: where(query, [row], row.ambiguous)
  defp filter_missing(query, _any), do: query

  defp any_missing do
    dynamic([row], not row.placed or not row.typed or not row.owned or row.ambiguous)
  end

  # One row per triage-eligible resource with a flag per fact.
  defp flagged_query(%Scope{organization_id: organization_id} = scope) do
    placed =
      from placement in CurrentPlacement,
        where:
          placement.organization_id == ^organization_id and
            placement.resource_id == parent_as(:resource).id

    typed =
      from assignment in HardwareAssignment,
        where:
          assignment.organization_id == ^organization_id and
            assignment.resource_id == parent_as(:resource).id

    ambiguous =
      scope
      |> ambiguous_attempts()
      |> where(
        [attempt],
        fragment(
          "? -> 'candidate_resource_ids' \\? (?)::text",
          attempt.errors,
          parent_as(:resource).id
        )
      )

    from resource in Resource,
      as: :resource,
      where: resource.organization_id == ^organization_id,
      where: resource.kind in ^@triage_kinds and resource.lifecycle_state != "retired",
      select: %{
        id: resource.id,
        inserted_at: resource.inserted_at,
        placed: exists(placed),
        typed: resource.kind not in ^@typed_kinds or exists(typed),
        owned: not is_nil(resource.owner_team_id),
        ambiguous: exists(ambiguous)
      }
  end

  # The latest attempt per observation, when it failed because several
  # resources matched. A later successful attempt clears it.
  defp ambiguous_attempts(%Scope{organization_id: organization_id}) do
    latest =
      from attempt in ObservationReconciliation,
        where: attempt.organization_id == ^organization_id,
        distinct: attempt.observation_id,
        order_by: [asc: attempt.observation_id, desc: attempt.attempt]

    from attempt in subquery(latest),
      where: attempt.status == "failed",
      where: fragment("? ->> 'identity' = 'ambiguous'", attempt.errors)
  end

  defp to_entries(rows, %Scope{organization_id: organization_id}) do
    ids = Enum.map(rows, & &1.id)

    resources =
      Resource
      |> where([resource], resource.organization_id == ^organization_id and resource.id in ^ids)
      |> preload([:host, :owner_team])
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, &%{resource: Map.fetch!(resources, &1.id), missing: missing_facts(&1)})
  end

  defp missing_facts(row) do
    Enum.filter(@facts, fn
      :placement -> not row.placed
      :hardware_type -> not row.typed
      :owner -> not row.owned
      :identity -> row.ambiguous
    end)
  end
end
