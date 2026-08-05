defmodule Renga.Inventory.ReconcilerTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.ResourceIdentifierClaim

  defp context do
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{
        name: "Reconciliation #{suffix}",
        slug: "reconciliation-#{suffix}"
      })

    scope = Accounts.scope_for(organization)

    {:ok, source} =
      Inventory.create_source(scope, %{kind: "host_agent", name: "host-agent-#{suffix}"})

    %{scope: scope, source: source}
  end

  defp observation(context, id, identifiers, attributes \\ %{}, interfaces \\ []) do
    observed_at = DateTime.add(~U[2026-08-01 12:00:00.000Z], String.to_integer(id), :second)

    {:ok, observation} =
      Inventory.create_observation(context.scope, context.source.id, %{
        idempotency_key: "observation-#{id}",
        observed_at: observed_at,
        payload: %{
          "observation_id" => "observation-#{id}",
          "observed_at" => DateTime.to_iso8601(observed_at),
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => identifiers,
              "attributes" => attributes,
              "interfaces" => interfaces
            }
          ]
        }
      })

    observation
  end

  test "discovers a host and preserves canonical identifiers and source claims" do
    context = context()

    observation =
      observation(
        context,
        "1",
        %{"hostname" => "Compute-01", "machine_id" => "AABBCCDD"},
        %{"hostname" => "Compute-01", "vendor" => "Dell", "model" => "R760"}
      )

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)
    assert resource.name == "compute-01"
    assert resource.lifecycle_state == "unknown"

    assert host = Inventory.get_host_by_resource!(context.scope, resource.id)
    assert host.hostname == "compute-01"
    assert host.vendor == "Dell"

    identifiers = Inventory.list_resource_identifiers(context.scope, resource.id)

    assert Enum.map(identifiers, &{&1.kind, &1.normalized_value}) == [
             {"hostname", "compute-01"},
             {"machine_id", "aabbccdd"}
           ]

    claims = Inventory.list_resource_identifier_claims(context.scope, resource.id)
    assert Enum.map(claims, &{&1.kind, &1.confidence}) == [{"hostname", 60}, {"machine_id", 100}]

    assert [%{status: "succeeded", matched_resource_id: resource_id}] =
             Inventory.list_observation_reconciliations(context.scope, observation.id)

    assert resource_id == resource.id
    assert [%{kind: "discovered"}] = Inventory.list_change_events(context.scope, resource.id)

    assert [%{type: "InventoryCurrent", status: "true"}] =
             Inventory.list_resource_conditions(context.scope, resource.id)
  end

  test "strong identity keeps a resource stable across hostname changes" do
    context = context()

    first =
      observation(context, "1", %{"hostname" => "compute-01", "machine_id" => "machine-1"}, %{
        "hostname" => "compute-01"
      })

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    second =
      observation(context, "2", %{"hostname" => "renamed-01", "machine_id" => "machine-1"}, %{
        "hostname" => "renamed-01"
      })

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert matched.id == resource.id
    assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "renamed-01"
    assert Inventory.list_resources(context.scope) |> Enum.map(& &1.id) == [resource.id]

    machine_claims =
      context.scope
      |> Inventory.list_resource_identifier_claims(resource.id)
      |> Enum.filter(&(&1.kind == "machine_id"))

    assert length(machine_claims) == 2
    assert Enum.at(machine_claims, 0).first_seen_at == first.observed_at
    assert Enum.at(machine_claims, 1).first_seen_at == first.observed_at
    assert Enum.at(machine_claims, 1).last_seen_at == second.observed_at
  end

  test "uses a unique hostname only when no strong identity is reported" do
    context = context()
    first = observation(context, "1", %{"hostname" => "compute-01"})
    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, first.id)

    second = observation(context, "2", %{"hostname" => "COMPUTE-01"})
    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, second.id)
    assert matched.id == resource.id

    strong =
      observation(context, "3", %{"hostname" => "compute-01", "machine_id" => "new-machine"})

    assert {:ok, distinct, true} = Inventory.reconcile_observation(context.scope, strong.id)
    refute distinct.id == resource.id
  end

  test "fails safely when a strong identifier belongs to duplicate resources" do
    context = context()

    resources =
      for name <- ~w(compute-01 compute-02) do
        {:ok, resource} = Inventory.create_resource(context.scope, %{kind: "server", name: name})

        {:ok, _identifier} =
          Inventory.create_resource_identifier(context.scope, resource.id, %{
            kind: "serial_number",
            value: "duplicate-serial"
          })

        resource
      end

    observation = observation(context, "1", %{"serial_number" => "duplicate-serial"})

    assert {:error, reconciliation} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert reconciliation.status == "failed"
    assert reconciliation.errors["identity"] == "ambiguous"

    assert Enum.sort(reconciliation.errors["candidate_resource_ids"]) ==
             Enum.sort(Enum.map(resources, & &1.id))

    assert Repo.get_by!(ResourceIdentifierClaim, observation_id: observation.id).resource_id ==
             nil

    assert length(Inventory.list_resources(context.scope)) == 2
  end

  test "matches an exact MAC address set after stronger identifiers miss" do
    context = context()

    {:ok, resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "compute-01"})

    for mac <- ~w(aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02) do
      {:ok, _identifier} =
        Inventory.create_resource_identifier(context.scope, resource.id, %{
          kind: "mac_address",
          value: mac
        })
    end

    observation =
      observation(context, "1", %{
        "machine_id" => "previously-unseen",
        "mac_address" => ~w(aa-bb-cc-dd-ee-01 aa-bb-cc-dd-ee-02)
      })

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    assert matched.id == resource.id
  end

  test "does not merge resources when different strong identifiers disagree" do
    context = context()

    {:ok, serial_resource} =
      Inventory.create_resource(context.scope, %{kind: "server", name: "serial"})

    {:ok, dmi_resource} = Inventory.create_resource(context.scope, %{kind: "server", name: "dmi"})

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, serial_resource.id, %{
        kind: "serial_number",
        value: "serial-1"
      })

    {:ok, _identifier} =
      Inventory.create_resource_identifier(context.scope, dmi_resource.id, %{
        kind: "dmi_uuid",
        value: "dmi-1"
      })

    observation =
      observation(context, "1", %{"serial_number" => "serial-1", "dmi_uuid" => "dmi-1"})

    assert {:error, reconciliation} =
             Inventory.reconcile_observation(context.scope, observation.id)

    assert Enum.sort(reconciliation.errors["candidate_resource_ids"]) ==
             Enum.sort([serial_resource.id, dmi_resource.id])

    assert Inventory.list_resource_identifiers(context.scope, serial_resource.id)
           |> Enum.map(& &1.kind) == ["serial_number"]
  end

  test "retrying an observation records another attempt without duplicating claims" do
    context = context()

    observation =
      observation(context, "1", %{"hostname" => "compute-01", "machine_id" => "machine-1"})

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, observation.id)
    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    assert matched.id == resource.id

    assert Enum.map(
             Inventory.list_observation_reconciliations(context.scope, observation.id),
             & &1.attempt
           ) == [1, 2]

    assert length(Inventory.list_resource_identifier_claims(context.scope, resource.id)) == 2
  end

  test "a repaired ambiguous observation can link its existing claim on retry" do
    context = context()

    resources =
      for name <- ~w(compute-01 compute-02) do
        {:ok, resource} = Inventory.create_resource(context.scope, %{kind: "server", name: name})

        {:ok, _identifier} =
          Inventory.create_resource_identifier(context.scope, resource.id, %{
            kind: "serial_number",
            value: "duplicate-serial"
          })

        resource
      end

    observation = observation(context, "1", %{"serial_number" => "duplicate-serial"})
    assert {:error, _result} = Inventory.reconcile_observation(context.scope, observation.id)

    [_kept, removed] = resources
    Repo.delete!(removed)

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, observation.id)
    claim = Repo.get_by!(ResourceIdentifierClaim, observation_id: observation.id)
    assert claim.resource_id == matched.id
    assert claim.resource_identifier_id
  end

  test "older observations preserve history without regressing the current projection" do
    context = context()

    newer =
      observation(context, "2", %{"machine_id" => "machine-1"}, %{"hostname" => "current-name"})

    assert {:ok, resource, true} = Inventory.reconcile_observation(context.scope, newer.id)

    older =
      observation(context, "1", %{"machine_id" => "machine-1"}, %{"hostname" => "old-name"})

    assert {:ok, matched, false} = Inventory.reconcile_observation(context.scope, older.id)
    assert matched.id == resource.id
    assert Inventory.get_host_by_resource!(context.scope, resource.id).hostname == "current-name"

    claims = Inventory.list_resource_identifier_claims(context.scope, resource.id)
    assert Enum.all?(claims, &(&1.first_seen_at == older.observed_at))

    [result] = Inventory.list_observation_reconciliations(context.scope, older.id)
    refute result.metadata["projection_applied"]

    [condition] = Inventory.list_resource_conditions(context.scope, resource.id)
    assert condition.details["observation_id"] == newer.id
  end

  test "same-name discoveries receive collision-resistant resource names" do
    context = context()

    resources =
      for id <- ~w(1 2 3) do
        observation =
          observation(context, id, %{"hostname" => "compute-01", "machine_id" => "machine-#{id}"})

        assert {:ok, resource, true} =
                 Inventory.reconcile_observation(context.scope, observation.id)

        resource
      end

    assert resources |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 3
  end
end
