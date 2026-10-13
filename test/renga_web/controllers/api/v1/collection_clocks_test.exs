defmodule RengaWeb.Api.V1.CollectionClocksTest do
  @moduledoc """
  The four collection clocks stay distinct through the real intake API
  (RFD 1, "Collection model"): each kind of request moves only the clocks it
  is evidence for.
  """
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Agent
  alias Renga.Inventory.AgentLease
  alias Renga.Inventory.AgentPayload
  alias Renga.Inventory.CollectionClocks
  alias Renga.Inventory.Observation
  alias Renga.Repo

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @long_ago ~U[2026-01-01 00:00:00.000000Z]

  setup do
    organization = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(admin, organization, %{role: "admin"})
    admin_scope = Accounts.scope_for_user(admin, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(admin_scope, %{name: "Fleet"})
    %{scope: Accounts.scope_for(organization), token: token}
  end

  test "a first check-in records contact and a lease but no inventory", context do
    assert %{"agent" => %{"id" => agent_id}} = check_in(context) |> json_response(202)

    agent = Repo.get!(Agent, agent_id) |> Repo.preload(:lease)
    assert agent.last_contacted_at
    assert agent.lease.renewed_at
    assert CollectionClocks.by_source(context.scope) == %{}
  end

  test "a rejected report counts as contact without renewing the lease", context do
    agent = registered_agent(context)
    rewind(agent)

    conn = post_observation(context, Map.delete(observation("rejected"), "observation_id"))
    assert json_response(conn, 422)

    agent = Repo.get!(Agent, agent.id) |> Repo.preload(:lease)
    assert DateTime.after?(agent.last_contacted_at, @long_ago)
    assert agent.lease.renewed_at == @long_ago
    assert CollectionClocks.by_source(context.scope) == %{}

    # A request that fails authentication is not contact at all.
    rewind(agent)

    build_conn()
    |> put_req_header("authorization", "Bearer renga_intake_revoked")
    |> put_req_header("x-renga-installation-id", @installation_id)
    |> post(~p"/api/v1/agent/checkins", %{})
    |> json_response(401)

    assert Repo.get!(Agent, agent.id).last_contacted_at == @long_ago
  end

  test "a failed reconciliation advances accepted but not reconciled", context do
    agent = registered_agent(context)

    conn = post_observation(context, observation("first", "2026-07-31T12:00:00Z"))
    assert %{"reconciliation" => %{"status" => "succeeded"}} = json_response(conn, 202)

    source_id = agent.source_id

    assert %CollectionClocks{
             reconciled_observed_at: ~U[2026-07-31 12:00:00.000000Z],
             latest_outcome: "succeeded"
           } = Map.fetch!(CollectionClocks.by_source(context.scope), source_id)

    # A newer observation is accepted, but its reconciliation fails.
    source = Inventory.get_source!(context.scope, source_id)
    payload = observation("second", "2026-07-31T13:00:00Z")
    {:ok, attrs} = AgentPayload.validate_observation(payload, source)
    {:ok, failed, :created} = Inventory.accept_observation(context.scope, source.id, attrs)
    now = Renga.Time.utc_now_ms()

    {:ok, _} =
      Inventory.create_observation_reconciliation(context.scope, failed.id, %{
        status: "failed",
        attempt: 1,
        errors: %{"processing" => "projection_failed"},
        started_at: now,
        completed_at: now
      })

    clocks = Map.fetch!(CollectionClocks.by_source(context.scope), source_id)
    assert clocks.accepted_at == Repo.get!(Observation, failed.id).inserted_at
    assert clocks.reconciled_observed_at == ~U[2026-07-31 12:00:00.000000Z]
    assert clocks.latest_outcome == "failed"

    # A later check-in renews contact and the lease, and touches neither
    # inventory clock.
    rewind(agent)
    assert json_response(check_in(context), 202)
    assert Map.fetch!(CollectionClocks.by_source(context.scope), source_id) == clocks
    agent = Repo.get!(Agent, agent.id) |> Repo.preload(:lease)
    assert DateTime.after?(agent.last_contacted_at, @long_ago)
    assert DateTime.after?(agent.lease.renewed_at, @long_ago)
  end

  defp registered_agent(context) do
    %{"agent" => %{"id" => agent_id}} = check_in(context) |> json_response(202)
    Repo.get!(Agent, agent_id)
  end

  # Puts contact and the lease renewal far in the past, so a test can see
  # which of them the next request moves.
  defp rewind(agent) do
    Repo.update_all(from(a in Agent, where: a.id == ^agent.id),
      set: [last_contacted_at: @long_ago]
    )

    Repo.update_all(from(l in AgentLease, where: l.agent_id == ^agent.id),
      set: [renewed_at: @long_ago]
    )
  end

  defp check_in(context) do
    context |> authorized() |> post(~p"/api/v1/agent/checkins", %{})
  end

  defp post_observation(context, payload) do
    context |> authorized() |> post(~p"/api/v1/observations", payload)
  end

  defp authorized(context) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{context.token}")
    |> put_req_header("x-renga-installation-id", @installation_id)
  end

  defp observation(id, observed_at \\ "2026-07-31T12:00:00Z") do
    %{
      "observation_id" => "clocks-#{id}",
      "observed_at" => observed_at,
      "source" => %{"kind" => "host_agent"},
      "resources" => [
        %{
          "kind" => "server",
          "identifiers" => %{"hostname" => "compute-01", "machine_id" => "9f3c7a8b"},
          "components" => []
        }
      ]
    }
  end
end
