defmodule Renga.Inventory.CollectorFindings do
  @moduledoc """
  Keeps the collector findings that time alone can open or resolve current
  (RFD 11, "Findings"): a target that stays silent past its freshness window
  opens a finding without any report arriving.

  They are refreshed after each collector report commits, and swept
  periodically by `Renga.Inventory.CollectorFindingsWorker`. Every refresh
  reads current evidence by the server's clock, so a report replayed late
  cannot make stale evidence look fresh.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.UnreachableTargets
  alias Renga.Repo

  @doc "Refreshes the organization's time-dependent collector findings as of `now`."
  def refresh!(%Scope{} = scope, now \\ Renga.Time.utc_now_ms()) do
    Repo.transaction(fn ->
      Inventory.lock_organization!(scope.organization_id)
      UnreachableTargets.refresh!(scope, now)
    end)
  end

  @doc """
  Active organizations whose collector evidence can open or resolve these
  findings: those with a collector target.
  """
  def organization_ids do
    CollectorTarget
    |> join(:inner, [target], organization in Organization,
      on: organization.id == target.organization_id
    )
    |> where([_target, organization], organization.status == "active")
    |> distinct(true)
    |> select([target], target.organization_id)
    |> Repo.all()
  end
end
