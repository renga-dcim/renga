defmodule Renga.TriageTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Teams
  alias Renga.Triage

  setup do
    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Renga.Accounts.scope_for_user(user, organization.id)
    %{scope: scope, organization: organization}
  end

  test "a new physical device lacks every fact a person supplies", %{scope: scope} do
    server = resource!(scope, "server", "web-01")

    assert {[%{resource: resource, missing: missing}], 1} = Triage.list_triage(scope)
    assert resource.id == server.id
    assert missing == [:placement, :hardware_type, :owner]
  end

  test "it leaves triage on its own as facts arrive", %{scope: scope} do
    server = resource!(scope, "server", "web-01")
    {:ok, team} = Teams.create_team(scope, %{"name" => "Platform"})
    {:ok, site} = DCIM.create_site(scope, %{name: "DC1"}, %{slug: "dc1"})

    {:ok, _server} = Teams.set_owner(scope, server, team.id)
    assert Triage.missing(scope, server) == [:placement, :hardware_type]

    {:ok, _placement} = DCIM.put_current_placement(scope, server.id, %{site_id: site.id})
    assert Triage.missing(scope, server) == [:hardware_type]

    {:ok, _assignment} =
      Catalog.assign_hardware_type(scope, server.id, hardware_type!(scope).id)

    assert Triage.missing(scope, server) == []
    assert {[], 0} = Triage.list_triage(scope)
  end

  test "only physical devices that are not retired enter triage", %{scope: scope} do
    resource!(scope, "vm", "vm-01")
    resource!(scope, "container", "app-01")
    resource!(scope, "storage", "nas-01") |> retire!(scope)

    {:ok, _retired} =
      Inventory.create_resource(scope, %{
        kind: "server",
        name: "old-01",
        lifecycle_state: "retired"
      })

    unknown = resource!(scope, "unknown", "mystery-01")

    assert {[%{resource: resource, missing: missing}], 1} = Triage.list_triage(scope)
    assert resource.id == unknown.id
    # Catalog hardware types do not apply to an unknown kind.
    refute :hardware_type in missing
  end

  test "an ambiguous report puts its candidates in triage until it matches", %{scope: scope} do
    first = resource!(scope, "server", "web-01")
    second = resource!(scope, "server", "web-02")
    observation = observation!(scope)

    {:ok, _attempt} = ambiguous_attempt(scope, observation, 1, [first.id, second.id])

    assert :identity in Triage.missing(scope, first)
    assert Enum.map(Triage.identity_candidates(scope, first), & &1.id) == [second.id]
    assert %{identity: 2} = Triage.counts(scope)

    {:ok, _retry} =
      Inventory.create_observation_reconciliation(scope, observation.id, %{
        status: "succeeded",
        attempt: 2,
        matched_resource_id: first.id,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    refute :identity in Triage.missing(scope, first)
    assert Triage.identity_candidates(scope, first) == []
  end

  test "a newer clean report clears only its own reporting identity", %{scope: scope} do
    first = resource!(scope, "server", "web-01")
    second = resource!(scope, "server", "web-02")
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "shared"})
    old = observation!(scope, source, ~U[2026-10-01 00:00:00Z])
    claim!(scope, old, "machine_id", "host-a")
    claim!(scope, old, "hostname", "shared-name")
    {:ok, _attempt} = ambiguous_attempt(scope, old, 1, [first.id, second.id])

    # Same source, candidate and hostname, but a different host must not clear it.
    other_host = observation!(scope, source, ~U[2026-10-02 00:00:00Z])
    claim!(scope, other_host, "machine_id", "host-b")
    claim!(scope, other_host, "hostname", "shared-name")
    succeed!(scope, other_host, first)
    assert :identity in Triage.missing(scope, first)

    clean = observation!(scope, source, ~U[2026-10-03 00:00:00Z])
    claim!(scope, clean, "machine_id", "host-a")
    succeed!(scope, clean, first)

    refute :identity in Triage.missing(scope, first)
    refute :identity in Triage.missing(scope, second)
    assert Triage.identity_candidates(scope, first) == []
    assert %{identity: 0} = Triage.counts(scope)
    assert {[], 0} = Triage.list_triage(scope, missing: :identity)
  end

  test "old clean reports and another source cannot supersede ambiguity", %{scope: scope} do
    first = resource!(scope, "server", "web-01")
    second = resource!(scope, "server", "web-02")
    {:ok, source} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-a"})
    old = observation!(scope, source, ~U[2026-10-01 00:00:00Z])
    claim!(scope, old, "machine_id", "host-a")
    succeed!(scope, old, first)
    ambiguous = observation!(scope, source, ~U[2026-10-02 00:00:00Z])
    claim!(scope, ambiguous, "machine_id", "host-a")
    {:ok, _attempt} = ambiguous_attempt(scope, ambiguous, 1, [first.id, second.id])

    {:ok, other} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-b"})
    clean = observation!(scope, other, ~U[2026-10-03 00:00:00Z])
    claim!(scope, clean, "machine_id", "host-a")
    succeed!(scope, clean, first)

    assert :identity in Triage.missing(scope, first)
    assert Enum.map(Triage.identity_candidates(scope, first), & &1.id) == [second.id]
  end

  test "filters by a missing fact and counts each", %{scope: scope} do
    owned = resource!(scope, "server", "web-01")
    resource!(scope, "server", "web-02")
    {:ok, team} = Teams.create_team(scope, %{"name" => "Platform"})
    {:ok, _owned} = Teams.set_owner(scope, owned, team.id)

    assert {[%{resource: %{name: "web-02"}}], 1} = Triage.list_triage(scope, missing: :owner)

    assert %{total: 2, placement: 2, hardware_type: 2, owner: 1, identity: 0} =
             Triage.counts(scope)
  end

  test "never includes another organization's resources", %{scope: scope} do
    other = organization_fixture()
    other_user = user_fixture()
    organization_membership_fixture(other_user, other, %{role: "admin"})
    other_scope = Renga.Accounts.scope_for_user(other_user, other.id)
    resource!(other_scope, "server", "theirs")

    assert {[], 0} = Triage.list_triage(scope)
  end

  defp resource!(scope, kind, name) do
    {:ok, resource} =
      Inventory.create_resource(scope, %{kind: kind, name: name, lifecycle_state: "active"})

    resource
  end

  defp retire!(resource, scope) do
    {:ok, resource} = Inventory.update_resource(scope, resource, %{lifecycle_state: "retired"})
    resource
  end

  defp observation!(scope, source \\ nil, observed_at \\ DateTime.utc_now()) do
    source =
      source ||
        elem(Inventory.create_source(scope, %{kind: "host_agent", name: "agent"}), 1)

    {:ok, observation} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "report-#{System.unique_integer([:positive])}",
        observed_at: observed_at,
        payload: %{"resources" => []}
      })

    observation
  end

  defp claim!(scope, observation, kind, value) do
    {:ok, claim} =
      Inventory.create_resource_identifier_claim(scope, observation.source_id, observation.id, %{
        kind: kind,
        value: value,
        first_seen_at: observation.observed_at,
        last_seen_at: observation.observed_at
      })

    claim
  end

  defp succeed!(scope, observation, resource) do
    {:ok, result} =
      Inventory.create_observation_reconciliation(scope, observation.id, %{
        status: "succeeded",
        attempt: 1,
        matched_resource_id: resource.id,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    result
  end

  defp ambiguous_attempt(scope, observation, attempt, candidates) do
    Inventory.create_observation_reconciliation(scope, observation.id, %{
      status: "failed",
      attempt: attempt,
      errors: %{"identity" => "ambiguous", "candidate_resource_ids" => candidates},
      started_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    })
  end

  defp hardware_type!(scope) do
    {:ok, manufacturer} =
      Catalog.create_manufacturer(scope, %{name: "Dell", lifecycle_state: "active"}, %{
        slug: "dell"
      })

    {:ok, hardware_type} =
      Catalog.create_hardware_type(
        scope,
        %{name: "R760", lifecycle_state: "active"},
        %{manufacturer_id: manufacturer.id, model: "R760", device_class: "server"}
      )

    {:ok, _revision} = Catalog.create_hardware_type_revision(scope, hardware_type, %{}, [])
    hardware_type
  end
end
