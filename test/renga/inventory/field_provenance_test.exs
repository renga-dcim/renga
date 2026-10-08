defmodule Renga.Inventory.FieldProvenanceTest do
  use Renga.DataCase, async: true

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.Changes

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, organization} =
      Accounts.create_organization(%{name: "Provenance #{suffix}", slug: "provenance-#{suffix}"})

    scope = member_scope(organization, "admin")
    {:ok, agent} = Inventory.create_source(scope, %{kind: "host_agent", name: "agent-#{suffix}"})
    {:ok, bmc} = Inventory.create_source(scope, %{kind: "bmc", name: "bmc-#{suffix}"})

    %{organization: organization, scope: scope, agent: agent, bmc: bmc}
  end

  describe "field_provenance/2" do
    test "sparse reports retain each source's last field-bearing observation", context do
      resource = report(context, context.agent, 1, %{"vendor" => "Agent"})
      report(context, context.bmc, 2, %{"vendor" => "Dell"})
      original = Inventory.field_provenance(context.scope, resource)["vendor"]
      report(context, context.bmc, 3, %{"hostname" => "bmc-name"})

      assert Inventory.field_provenance(context.scope, resource)["vendor"] == original

      {:ok, _} =
        Inventory.set_field_override(context.scope, resource, "vendor", %{"value" => "HPE"})

      {:ok, host} = Inventory.clear_field_override(context.scope, resource, "vendor")
      assert host.vendor == "Dell"

      assert host.metadata["field_owners"]["vendor"]["observation_id"] ==
               hd(original.candidates).observation_id
    end

    test "removing an override after a sparse single-source report does not clear the value",
         context do
      resource = report(context, context.agent, 1, %{"vendor" => "Agent"})
      report(context, context.agent, 2, %{"hostname" => "agent-name"})

      {:ok, _} =
        Inventory.set_field_override(context.scope, resource, "vendor", %{"value" => "HPE"})

      {:ok, host} = Inventory.clear_field_override(context.scope, resource, "vendor")
      assert host.vendor == "Agent"
    end

    test "lists every source's report, the winner first, and why it won", context do
      resource =
        report(context, context.agent, 1, %{"hostname" => "agent-name", "vendor" => "Agent"})

      report(context, context.bmc, 2, %{"hostname" => "bmc-name", "vendor" => "Dell"})

      provenance = Inventory.field_provenance(context.scope, resource)

      assert %{value: "Dell", candidates: [winner, loser], reason: reason} = provenance["vendor"]
      assert {winner.source.id, winner.value, winner.winner?} == {context.bmc.id, "Dell", true}
      assert {loser.source.id, loser.value, loser.winner?} == {context.agent.id, "Agent", false}
      assert reason =~ "Management controllers are trusted most"

      assert %{value: "agent-name", candidates: [%{source: source, winner?: true}, _]} =
               provenance["hostname"]

      assert source.id == context.agent.id
      assert provenance["hostname"].reason =~ "Host agents are trusted"
    end

    test "explains a single reporter and a field nobody reports", context do
      resource = report(context, context.agent, 1, %{"hostname" => "only-agent"})
      provenance = Inventory.field_provenance(context.scope, resource)

      assert provenance["hostname"].reason == "Only #{context.agent.name} reports this field."
      assert provenance["asset_tag"] == %{provenance["asset_tag"] | candidates: [], value: nil}
      assert provenance["asset_tag"].reason == "No source reports this field."
    end

    test "flags drift against desired state", context do
      resource = report(context, context.agent, 1, %{"model" => "R750"})

      {:ok, resource} =
        Inventory.update_resource(context.scope, resource, %{
          spec: %{"host" => %{"model" => "R760"}, "hostname" => "web-01"}
        })

      provenance = Inventory.field_provenance(context.scope, resource)

      assert %{value: "R750", expected: "R760", drift?: true} = provenance["model"]
      assert %{expected: "web-01", drift?: true} = provenance["hostname"]
      assert %{expected: nil, drift?: false} = provenance["vendor"]
    end
  end

  describe "set_field_override/4" do
    test "pins the value, wins over every source, and replaces an earlier override", context do
      resource = report(context, context.bmc, 1, %{"vendor" => "Dell"})
      :ok = Changes.subscribe(context.scope)

      assert {:ok, override} =
               Inventory.set_field_override(context.scope, resource, "vendor", %{
                 "value" => " Supermicro ",
                 "reason" => "Relabelled chassis"
               })

      assert override.value == %{"value" => "Supermicro"}
      assert_receive {:inventory_changed, _organization_id}

      provenance = Inventory.field_provenance(context.scope, resource)
      assert provenance["vendor"].value == "Supermicro"
      assert provenance["vendor"].override.reason == "Relabelled chassis"
      assert provenance["vendor"].override.created_by_user.id == context.scope.user.id
      assert provenance["vendor"].reason == "Overrides set by people always win."
      assert [%{winner?: false, value: "Dell"}] = provenance["vendor"].candidates

      assert {:ok, _replacement} =
               Inventory.set_field_override(context.scope, resource, "vendor", %{
                 "value" => "Lenovo"
               })

      assert [%{value: %{"value" => "Lenovo"}}] =
               Inventory.list_resource_overrides(context.scope, resource.id)

      assert Inventory.get_host_by_resource!(context.scope, resource.id).vendor == "Lenovo"
    end

    test "rejects a blank value", context do
      resource = report(context, context.bmc, 1, %{"vendor" => "Dell"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Inventory.set_field_override(context.scope, resource, "vendor", %{"value" => " "})

      assert "can't be blank" in errors_on(changeset).value
      assert Inventory.list_resource_overrides(context.scope, resource.id) == []
    end

    test "requires the owner or admin role", context do
      resource = report(context, context.bmc, 1, %{"vendor" => "Dell"})
      member = member_scope(context.organization, "member")

      assert {:error, :forbidden} =
               Inventory.set_field_override(member, resource, "vendor", %{"value" => "HPE"})

      assert {:error, :forbidden} = Inventory.clear_field_override(member, resource, "vendor")
      assert Inventory.get_host_by_resource!(context.scope, resource.id).vendor == "Dell"
    end
  end

  describe "clear_field_override/3" do
    test "hands the field back to the source reconciliation would choose", context do
      resource = report(context, context.agent, 1, %{"vendor" => "Agent"})
      report(context, context.bmc, 2, %{"vendor" => "Dell"})

      {:ok, _override} =
        Inventory.set_field_override(context.scope, resource, "vendor", %{"value" => "HPE"})

      assert {:ok, host} = Inventory.clear_field_override(context.scope, resource, "vendor")
      assert host.vendor == "Dell"
      assert host.metadata["field_owners"]["vendor"]["source_id"] == context.bmc.id
      assert Inventory.list_resource_overrides(context.scope, resource.id) == []

      assert %{kind: "override_removed", old_value: %{"value" => "HPE"}} =
               context.scope
               |> Inventory.list_change_events(resource.id)
               |> Enum.find(&(&1.kind == "override_removed"))

      # Later reports reconcile normally again.
      report(context, context.bmc, 3, %{"vendor" => "Dell EMC"})
      assert Inventory.get_host_by_resource!(context.scope, resource.id).vendor == "Dell EMC"
    end

    test "clears a value no source reports", context do
      resource = report(context, context.agent, 1, %{"hostname" => "web-01"})

      {:ok, _override} =
        Inventory.set_field_override(context.scope, resource, "asset_tag", %{"value" => "A-1"})

      assert {:ok, host} = Inventory.clear_field_override(context.scope, resource, "asset_tag")
      assert host.asset_tag == nil
      refute Map.has_key?(host.metadata["field_owners"], "asset_tag")
    end

    test "reports a field without an override", context do
      resource = report(context, context.agent, 1, %{"hostname" => "web-01"})

      assert {:error, :not_found} =
               Inventory.clear_field_override(context.scope, resource, "hostname")
    end
  end

  # Records and reconciles one report from `source` about the same machine.
  defp report(context, source, second, attributes) do
    observed_at = DateTime.add(~U[2026-08-01 12:00:00.000Z], second, :second)
    key = "#{source.id}-#{second}"

    {:ok, observation} =
      Inventory.create_observation(context.scope, source.id, %{
        idempotency_key: key,
        observed_at: observed_at,
        payload: %{
          "observation_id" => key,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "resources" => [
            %{
              "kind" => "server",
              "identifiers" => %{"machine_id" => "machine-1"},
              "attributes" => attributes
            }
          ]
        }
      })

    {:ok, resource, _created?} = Inventory.reconcile_observation(context.scope, observation.id)
    resource
  end

  defp member_scope(organization, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "#{role}-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, _membership} =
      Accounts.create_organization_membership(organization, %{
        user_id: user.id,
        role: role,
        status: "active"
      })

    Accounts.scope_for_user(user, organization.id)
  end
end
