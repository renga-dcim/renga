defmodule Renga.FindingsFixtures do
  @moduledoc """
  Inserts finding rows directly, standing in for the reconcilers that open
  them, so Inbox and workflow tests can set up any domain's finding without
  replaying collector reports.
  """

  alias Renga.Catalog.ComponentFinding
  alias Renga.Repo
  alias Renga.Topology.TopologyFinding

  @doc """
  A component finding on `resource`. Options: `:status`, `:key`
  (resolution key), and `:minutes_ago` (last observed).
  """
  def component_finding_fixture(resource, kind, opts \\ []) do
    status = Keyword.get(opts, :status, "open")
    at = minutes_ago(opts)

    Repo.insert!(%ComponentFinding{
      organization_id: resource.organization_id,
      resource_id: resource.id,
      kind: kind,
      resolution_key: Keyword.get(opts, :key, "assignment:1:template:1"),
      status: status,
      message: "Finding #{kind}",
      last_observed_at: at,
      resolved_at: if(status == "resolved", do: at)
    })
  end

  @doc """
  A finding in a table keyed only by resource and kind:
  `Renga.Catalog.HardwareMatchFinding` or `Renga.DCIM.PlacementFinding`.
  """
  def resource_finding_fixture(schema, resource, kind, opts \\ []) do
    at = minutes_ago(opts)

    Repo.insert!(
      struct(schema,
        organization_id: resource.organization_id,
        resource_id: resource.id,
        kind: kind,
        status: "open",
        message: "Finding #{kind}",
        inserted_at: at,
        updated_at: at
      )
    )
  end

  @doc "A topology finding on `interface`."
  def topology_finding_fixture(interface, kind, opts \\ []) do
    Repo.insert!(%TopologyFinding{
      organization_id: interface.organization_id,
      interface_id: interface.id,
      kind: kind,
      resolution_key: Keyword.get(opts, :key, "drift:1"),
      status: "open",
      message: "Finding #{kind}",
      last_observed_at: minutes_ago(opts)
    })
  end

  defp minutes_ago(opts),
    do: DateTime.add(DateTime.utc_now(), -60 * Keyword.get(opts, :minutes_ago, 0))
end
