defmodule Renga.Inventory.CollectorFindings do
  @moduledoc """
  Keeps the collector findings that time alone can open or resolve current
  (RFD 11, "Findings"): a target that stays silent past its freshness window
  opens a finding without any report arriving, a VM's competing claim going
  stale resolves one, and so does a guest's agent disconnecting.

  They are refreshed after each collector report commits, and swept
  periodically by `Renga.Inventory.CollectorFindingsWorker`. Every refresh
  reads current evidence by the server's clock, so a report replayed late
  cannot make stale evidence look fresh.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Authorization
  alias Renga.Accounts.Scope
  alias Renga.Inventory
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.Changes
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.CollectorTarget
  alias Renga.Inventory.CompetingPlacements
  alias Renga.Inventory.GuestsWithoutVm
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Resource
  alias Renga.Inventory.UnreachableTargets
  alias Renga.Repo

  @timed_kinds ~w(target_unreachable vm_active_on_two_hypervisors guest_without_vm)

  @doc "Refreshes the organization's time-dependent collector findings as of `now`."
  def refresh!(%Scope{} = scope, now \\ Renga.Time.utc_now_ms()) do
    Repo.transaction(fn ->
      Inventory.lock_organization!(scope.organization_id)
      UnreachableTargets.refresh!(scope, now)
      CompetingPlacements.refresh!(scope, now)
      GuestsWithoutVm.refresh!(scope, now)
    end)
  end

  @doc "Whether the organization opted in to guest-without-VM findings."
  def guest_without_vm_findings?(%Scope{} = scope), do: GuestsWithoutVm.enabled?(scope)

  @doc """
  Opts the organization in to, or out of, guest-without-VM findings (RFD
  11, "Decisions from review"), and refreshes them at once. It changes
  what everyone's Inbox shows, so it takes `organization.manage`, like the
  organization's other settings, and is recorded in Activity.
  """
  def set_guest_without_vm_findings(%Scope{user: %User{}} = scope, enabled?)
      when is_boolean(enabled?) do
    fn ->
      Authorization.authorize!(scope, "organization.manage")
      Inventory.lock_organization!(scope.organization_id)
      stored = Repo.get!(Organization, scope.organization_id)

      if stored.guest_without_vm_findings != enabled? do
        stored
        |> Ecto.Changeset.change(guest_without_vm_findings: enabled?)
        |> Repo.update!()

        {:ok, _event} =
          Inventory.create_change_event(scope, %{
            kind: "updated",
            field: "guest_without_vm_findings",
            old_value: %{"enabled" => stored.guest_without_vm_findings},
            new_value: %{"enabled" => enabled?}
          })

        GuestsWithoutVm.refresh!(scope, Renga.Time.utc_now_ms())
      end

      enabled?
    end
    |> Repo.transaction()
    |> Changes.broadcast(scope.organization_id)
  end

  def set_guest_without_vm_findings(_scope, _enabled?), do: {:error, :forbidden}

  @doc """
  Refreshes what one reconciled observation may have changed: everything,
  for a collector report, or the machine a host agent reported.
  """
  def refresh_after!(%Scope{} = scope, %Observation{payload: payload}, result) do
    now = Renga.Time.utc_now_ms()

    cond do
      AgentPayload.scoped_report?(payload) ->
        refresh!(scope, now)

      # Most organizations never opt in, so a host report takes the
      # organization lock only when one has.
      match?({:ok, %Resource{}, _discovered?}, result) and GuestsWithoutVm.enabled?(scope) ->
        {:ok, resource, _discovered?} = result

        Repo.transaction(fn ->
          Inventory.lock_organization!(scope.organization_id)
          GuestsWithoutVm.refresh_guest!(scope, resource.id, now)
        end)

      true ->
        {:ok, :ok}
    end
  end

  @doc """
  Active organizations whose collector evidence can open or resolve these
  findings: those with a collector target, or with an open finding that
  time could resolve.
  """
  def organization_ids do
    with_findings =
      CollectorFinding
      |> where([finding], finding.status == "open" and finding.kind in ^@timed_kinds)
      |> select([finding], finding.organization_id)

    CollectorTarget
    |> select([target], target.organization_id)
    |> union(^with_findings)
    |> subquery()
    |> join(:inner, [row], organization in Organization,
      on: organization.id == row.organization_id
    )
    |> where([_row, organization], organization.status == "active")
    |> distinct(true)
    |> select([row], row.organization_id)
    |> Repo.all()
  end
end
