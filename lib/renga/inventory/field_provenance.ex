defmodule Renga.Inventory.FieldProvenance do
  @moduledoc """
  Where each displayed host value comes from (RFD 8, "Values, provenance,
  and drift"): what every source last reported, which one won and why, any
  override, and the expected value from desired state.

  Each source's value is read from its latest observation matched to the
  resource, through the same extraction reconciliation uses, so the
  comparison shows exactly what reconciliation saw. The winner is the owner
  reconciliation recorded on the field; the explanation comes from
  `Renga.Inventory.SourcePrecedence`, the rule reconciliation applies.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Host
  alias Renga.Inventory.Observation
  alias Renga.Inventory.ObservationReconciliation
  alias Renga.Inventory.Reconciler.Projections
  alias Renga.Inventory.Resource
  alias Renga.Inventory.ResourceOverride
  alias Renga.Inventory.SourcePrecedence
  alias Renga.Repo

  @fields ~w(hostname fqdn vendor model asset_tag)

  @doc "The host fields that carry provenance."
  def fields, do: @fields

  @doc """
  Provenance for every host field of a resource, keyed by field name.

  Each entry has `:value` (current), `:expected` (desired, or nil),
  `:drift?`, `:override` (a `%ResourceOverride{}` or nil), `:candidates`
  (what each source last reported, the winner first), and `:reason`.
  """
  def for_host(%Scope{organization_id: organization_id} = scope, %Resource{} = resource) do
    host = Repo.get_by(Host, organization_id: organization_id, resource_id: resource.id)
    owners = get_in((host && host.metadata) || %{}, ["field_owners"]) || %{}
    overrides = overrides_by_field(scope, resource)
    observations = latest_observations(organization_id, resource.id)

    Map.new(@fields, fn field ->
      path = "host." <> field
      value = host && Map.get(host, String.to_existing_atom(field))
      expected = expected_value(resource.spec, field)
      override = Map.get(overrides, path)

      candidates =
        observations
        |> candidates(field, path, Map.get(owners, field))
        |> without_winner(override)

      {field,
       %{
         field: field,
         path: path,
         value: value,
         expected: expected,
         drift?: not is_nil(expected) and expected != value,
         override: override,
         candidates: candidates,
         reason: reason(override, candidates, path)
       }}
    end)
  end

  @doc """
  The report that would hold `field` if nobody had overridden it, or nil
  when no source reports the field. Removing an override restores this.
  """
  def source_choice(%Scope{organization_id: organization_id}, %Resource{} = resource, field)
      when field in @fields do
    organization_id
    |> latest_observations(resource.id)
    |> candidates(field, "host." <> field, nil)
    |> Enum.find(& &1.winner?)
  end

  @doc """
  The candidate reconciliation would choose without an override: highest
  source priority, then most recent report. Ties break the same way the
  reconciler does.
  """
  def best_candidate([], _path), do: nil

  def best_candidate(candidates, path) do
    Enum.max_by(candidates, fn candidate ->
      {SourcePrecedence.priority(candidate.source.kind, path),
       DateTime.to_unix(candidate.observed_at, :microsecond), candidate.source.id,
       candidate.observation_id}
    end)
  end

  # Sparse reports leave omitted fields unchanged. Keep history until we
  # have selected the latest field-bearing report for each source.
  defp latest_observations(organization_id, resource_id) do
    from(observation in Observation,
      join: reconciliation in ObservationReconciliation,
      on: reconciliation.observation_id == observation.id,
      where:
        observation.organization_id == ^organization_id and
          reconciliation.organization_id == ^organization_id and
          reconciliation.matched_resource_id == ^resource_id and
          reconciliation.status == "succeeded",
      order_by: [asc: observation.source_id, desc: observation.observed_at, desc: observation.id],
      preload: [:source]
    )
    |> Repo.all()
  end

  defp candidates(observations, field, path, owner) do
    candidates =
      for observation <- observations,
          value = observation.payload |> Projections.host_attrs() |> Map.get(field),
          not is_nil(value) do
        %{
          source: observation.source,
          value: value,
          observed_at: observation.observed_at,
          observation_id: observation.id,
          winner?: false
        }
      end

    candidates = Enum.uniq_by(candidates, & &1.source.id)
    winner = recorded_winner(candidates, owner) || best_candidate(candidates, path)

    candidates
    |> Enum.map(&%{&1 | winner?: winner != nil and &1.observation_id == winner.observation_id})
    |> Enum.sort_by(&{not &1.winner?, &1.source.name})
  end

  # An override holds the field, so no report is in effect.
  defp without_winner(candidates, nil), do: candidates

  defp without_winner(candidates, %ResourceOverride{}),
    do: candidates |> Enum.map(&%{&1 | winner?: false}) |> Enum.sort_by(& &1.source.name)

  # The owner reconciliation stored on the field, when it is still one of
  # the latest reports. A manual owner means an override holds the field.
  defp recorded_winner(_candidates, nil), do: nil
  defp recorded_winner(_candidates, %{"source_kind" => "manual"}), do: nil

  defp recorded_winner(candidates, %{"observation_id" => observation_id}),
    do: Enum.find(candidates, &(&1.observation_id == observation_id))

  defp recorded_winner(_candidates, _owner), do: nil

  defp reason(%ResourceOverride{}, _candidates, path),
    do: SourcePrecedence.explain("manual", path)

  defp reason(nil, [], _path), do: "No source reports this field."

  defp reason(nil, [only], _path), do: "Only #{only.source.name} reports this field."

  defp reason(nil, candidates, path) do
    winner = Enum.find(candidates, & &1.winner?)
    winner_priority = SourcePrecedence.priority(winner.source.kind, path)

    tied? =
      Enum.any?(
        candidates,
        &(not &1.winner? and SourcePrecedence.priority(&1.source.kind, path) == winner_priority)
      )

    if tied?,
      do: "#{winner.source.name} reported most recently among equally trusted sources.",
      else: SourcePrecedence.explain(winner.source.kind, path)
  end

  defp overrides_by_field(%Scope{organization_id: organization_id}, %Resource{id: resource_id}) do
    ResourceOverride
    |> where([override], override.organization_id == ^organization_id)
    |> where([override], override.resource_id == ^resource_id)
    |> preload(:created_by_user)
    |> Repo.all()
    |> Map.new(&{&1.field, &1})
  end

  # Matches the reconciler: desired host values live under "host" or, for
  # older specs, at the top level.
  defp expected_value(spec, field) when is_map(spec) do
    case get_in(spec, ["host", field]) || Map.get(spec, field) do
      value when is_binary(value) -> value
      _missing_or_structured -> nil
    end
  end

  defp expected_value(_spec, _field), do: nil
end
