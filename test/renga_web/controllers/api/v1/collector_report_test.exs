defmodule RengaWeb.Api.V1.CollectorReportTest do
  @moduledoc """
  RFD 11 phase 1: collector streams and scoped, multi-resource reports.
  """

  use RengaWeb.ConnCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.CollectionClocks
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Collectors
  alias Renga.Inventory.Observation
  alias Renga.Inventory.Reconciler
  alias Renga.Repo

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"
  @other_installation_id "8ea9ae04-bf9b-4c34-8192-4f617eade95e"

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    %{scope: scope, token: token}
  end

  describe "collector streams" do
    test "a module reports through its own stream without retyping the host source", %{
      scope: scope,
      token: token
    } do
      host = post_observation(token, host_report())
      assert %{"observation" => %{"source_id" => host_source_id}} = valid_api_response(host, 202)

      report = post_observation(token, switch_report([switch("10.0.0.1", "SER-1")]))

      assert %{"observation" => %{"source_id" => stream_id}} = valid_api_response(report, 202)
      refute stream_id == host_source_id

      [agent] = Inventory.list_agents(scope)
      assert agent.source_id == host_source_id
      assert Inventory.get_source!(scope, host_source_id).kind == "host_agent"

      assert [stream] = Collectors.list_streams(scope)
      assert stream.id == stream_id
      assert stream.kind == "switch_poller"
      assert stream.collector_id == "core-switches"
      assert stream.agent_id == agent.id
    end

    test "a collector ID keeps its stream when targets change, and each ID gets its own", %{
      scope: scope,
      token: token
    } do
      first = post_observation(token, switch_report([switch("10.0.0.1", "SER-1")]))
      moved = post_observation(token, switch_report([switch("10.0.9.9", "SER-1")]))

      other =
        post_observation(
          token,
          switch_report([switch("10.0.0.1", "SER-1")], collector_id: "edge-switches")
        )

      assert %{"observation" => %{"source_id" => stream_id}} = valid_api_response(first, 202)
      assert %{"observation" => %{"source_id" => ^stream_id}} = valid_api_response(moved, 202)
      assert %{"observation" => %{"source_id" => other_id}} = valid_api_response(other, 202)
      refute other_id == stream_id

      # Another installation's module with the same ID is a different stream.
      elsewhere =
        post_observation(token, switch_report([switch("10.0.0.1", "SER-1")]),
          installation_id: @other_installation_id
        )

      assert %{"observation" => %{"source_id" => elsewhere_id}} =
               valid_api_response(elsewhere, 202)

      refute elsewhere_id in [stream_id, other_id]
      assert length(Collectors.list_streams(scope)) == 3
    end

    test "a stream's kind never changes", %{scope: scope, token: token} do
      assert %{"status" => "accepted"} =
               token
               |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
               |> valid_api_response(202)

      conflict =
        post_observation(
          token,
          hypervisor_report([vm("VM-UUID-1")], collector_id: "core-switches")
        )

      assert %{"errors" => [%{"path" => "collector.kind"}]} = valid_api_response(conflict, 409)

      # Nor can an update retype it, which would misfile its queued reports.
      [stream] = Collectors.list_streams(scope)

      assert {:error, changeset} =
               Inventory.update_source(scope, stream, %{kind: "vm_provider"})

      assert %{kind: ["can't change for a collector stream"]} =
               Renga.DataCase.errors_on(changeset)

      assert {:ok, _renamed} = Inventory.update_source(scope, stream, %{name: "core switches"})
    end

    test "a disabled stream rejects reports", %{scope: scope, token: token} do
      token
      |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
      |> valid_api_response(202)

      [stream] = Collectors.list_streams(scope)
      {:ok, _stream} = Inventory.update_source(scope, stream, %{status: "disabled"})

      rejected = post_observation(token, switch_report([switch("10.0.0.1", "SER-1")]))
      assert %{"errors" => [%{"path" => "collector.id"}]} = valid_api_response(rejected, 409)
    end

    test "stream inventory clocks are the stream's own", %{scope: scope, token: token} do
      token |> post_observation(host_report()) |> valid_api_response(202)

      report =
        post_observation(
          token,
          switch_report([switch("10.0.0.1", "SER-1")], observed_at: "2026-08-13T07:00:00Z")
        )

      assert %{"observation" => %{"source_id" => stream_id}} = valid_api_response(report, 202)

      # A later host report moves only the host source's clocks.
      token
      |> post_observation(host_report(observed_at: "2026-08-13T09:00:00Z"))
      |> valid_api_response(202)

      clocks = CollectionClocks.by_source(scope)
      stream_clocks = Map.fetch!(clocks, stream_id)
      assert stream_clocks.reconciled_observed_at == ~U[2026-08-13 07:00:00.000000Z]
      assert stream_clocks.latest_outcome == "succeeded"
    end
  end

  describe "scoped reports" do
    test "each resource reconciles on its own", %{scope: scope, token: token} do
      conn =
        post_observation(
          token,
          switch_report([switch("10.0.0.1", "SER-1"), switch("10.0.0.2", "SER-2")])
        )

      assert %{
               "reconciliation" => %{
                 "status" => "succeeded",
                 "resources" => [
                   %{"status" => "succeeded", "resource_id" => first_id},
                   %{"status" => "succeeded", "resource_id" => second_id}
                 ]
               },
               "observation" => %{"id" => report_id}
             } = valid_api_response(conn, 202)

      refute first_id == second_id
      assert Inventory.get_resource!(scope, first_id).kind == "switch"

      derived = Inventory.list_derived_observations(scope, report_id)
      assert Enum.map(derived, & &1.resource_index) == [0, 1]
      assert Enum.map(derived, & &1.payload["target"]) == ["10.0.0.1", "10.0.0.2"]

      # Each derived observation carries only the collector's normalized
      # identity; the rest of the collector object stays in the raw report.
      padded =
        switch_report([switch("10.0.0.1", "SER-1"), switch("10.0.0.2", "SER-2")])
        |> put_in(["collector", "id"], "  core-switches  ")
        |> put_in(["collector", "notes"], String.duplicate("x", 1_000))

      assert %{"observation" => %{"id" => padded_id}} =
               token |> post_observation(padded) |> valid_api_response(202)

      assert Repo.get!(Observation, padded_id).payload["collector"]["notes"]

      for derived <- Inventory.list_derived_observations(scope, padded_id) do
        assert derived.payload["collector"] == %{
                 "id" => "core-switches",
                 "kind" => "switch_poller"
               }
      end

      # A resent report is the stored one, reconciled once.
      duplicate =
        post_observation(
          token,
          switch_report([switch("10.0.0.1", "SER-1"), switch("10.0.0.2", "SER-2")],
            observation_id: Repo.get!(Observation, report_id).idempotency_key
          )
        )

      assert %{
               "duplicate" => true,
               "reconciliation" => %{"resources" => [_first, _second]}
             } = valid_api_response(duplicate, 200)

      assert length(Inventory.list_derived_observations(scope, report_id)) == 2
    end

    test "a later report of the same chassis serial matches the same switch", %{token: token} do
      first = post_observation(token, switch_report([switch("10.0.0.1", "SER-1")]))
      second = post_observation(token, switch_report([switch("10.0.0.7", "SER-1")]))

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => id}]}} =
               valid_api_response(first, 202)

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => ^id}]}} =
               valid_api_response(second, 202)
    end

    for order <- [:host_first, :collector_first],
        {kind, resource_kind, collector_id} <- [
          {"switch_poller", "switch", "core-switches"},
          {"power_poller", "pdu", "rack-pdus"}
        ] do
      test "names and MAC addresses alone never merge a #{resource_kind} (#{order})", %{
        token: token
      } do
        lookalike =
          "10.0.0.1"
          |> switch("SER-1",
            hostname: "core1",
            interfaces: [
              %{"name" => "eth0", "kind" => "ethernet", "mac_address" => "52:54:00:00:00:01"}
            ]
          )
          |> Map.put("kind", unquote(resource_kind))

        same_mac = host_report(mac: "52:54:00:00:00:01")

        # With no stable identifier, a host report falls back to its name.
        same_name =
          update_in(
            host_report(hostname: "core1"),
            ["resources", Access.at(0), "identifiers"],
            &Map.delete(&1, "machine_id")
          )

        post = fn report -> token |> post_observation(report) |> valid_api_response(202) end

        hosts = fn ->
          Enum.map([same_mac, same_name], &post.(&1)["reconciliation"]["matched_resource_id"])
        end

        switch_id = fn ->
          %{"reconciliation" => %{"resources" => [%{"resource_id" => id}]}} =
            post.(
              switch_report([lookalike],
                kind: unquote(kind),
                collector_id: unquote(collector_id)
              )
            )

          id
        end

        {switch_id, host_ids} =
          if unquote(order) == :host_first do
            host_ids = hosts.()
            {switch_id.(), host_ids}
          else
            switch_id = switch_id.()
            {switch_id, hosts.()}
          end

        refute switch_id in host_ids
      end
    end

    test "a VM whose UUID a guest agent reports reconciles to the guest's resource", %{
      token: token
    } do
      host =
        post_observation(token, host_report(dmi_uuid: "4c4c4544-0000-1111-2222-333344445555"))

      assert %{"reconciliation" => %{"matched_resource_id" => guest_id}} =
               valid_api_response(host, 202)

      report =
        post_observation(token, hypervisor_report([vm("4c4c4544-0000-1111-2222-333344445555")]))

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => ^guest_id}]}} =
               valid_api_response(report, 202)
    end
  end

  describe "targets and retirement" do
    test "an unreachable target is unknown, never absent", %{scope: scope, token: token} do
      token
      |> post_observation(switch_report([switch("10.0.0.1", "SER-1")], complete: true))
      |> valid_api_response(202)

      unreachable =
        switch_report([],
          targets: [%{"address" => "10.0.0.1", "status" => "unreachable", "error" => "timeout"}],
          complete: true,
          observed_at: "2026-08-13T08:00:00Z"
        )

      token |> post_observation(unreachable) |> valid_api_response(202)

      [stream] = Collectors.list_streams(scope)
      assert [target] = Collectors.list_targets(scope, stream.id)
      assert target.status == "unreachable"
      assert target.error == "timeout"
      assert target.last_reachable_at == ~U[2026-08-13 07:30:00.000000Z]

      assert [member] = Collectors.list_target_resources(scope, stream.id)
      assert CollectorTargetResource.present?(member)
      assert inventory_current(scope, member.resource_id) == "true"
    end

    test "only a complete report withdraws what a target no longer reports", %{
      scope: scope,
      token: token
    } do
      token
      |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
      |> valid_api_response(202)

      # The switch at the address was replaced. A partial report adds the new
      # one without deciding the old one is gone.
      token
      |> post_observation(
        switch_report([switch("10.0.0.1", "SER-2")], observed_at: "2026-08-13T08:00:00Z")
      )
      |> valid_api_response(202)

      [stream] = Collectors.list_streams(scope)
      assert Enum.all?(Collectors.list_target_resources(scope, stream.id), &present?/1)

      complete =
        post_observation(
          token,
          switch_report([switch("10.0.0.1", "SER-2")],
            observed_at: "2026-08-13T09:00:00Z",
            complete: true
          )
        )

      valid_api_response(complete, 202)

      members = Collectors.list_target_resources(scope, stream.id)
      old = Enum.find(members, &(serial(scope, &1) == "SER-1"))
      new = Enum.find(members, &(&1 != old))

      refute present?(old)
      assert old.withdrawn_at == ~U[2026-08-13 09:00:00.000000Z]
      assert present?(new)
      assert inventory_current(scope, old.resource_id) == "false"
      assert inventory_current(scope, new.resource_id) == "true"

      assert Enum.any?(
               Inventory.list_change_events(scope, old.resource_id),
               &(&1.kind == "withdrawn")
             )

      # A report from before the withdrawal, replayed late, changes nothing.
      token
      |> post_observation(
        switch_report([switch("10.0.0.1", "SER-1")],
          observed_at: "2026-08-13T08:30:00Z",
          complete: true
        )
      )
      |> valid_api_response(202)

      old = Enum.find(Collectors.list_target_resources(scope, stream.id), &(&1.id == old.id))
      refute present?(old)
      assert inventory_current(scope, old.resource_id) == "false"
      [target] = Collectors.list_targets(scope, stream.id)
      assert target.last_reported_at == ~U[2026-08-13 09:00:00.000000Z]

      assert present?(
               Enum.find(Collectors.list_target_resources(scope, stream.id), &(&1.id == new.id))
             )

      # A later complete report confirms the withdrawal, so a report from
      # between the two complete ones, replayed late, cannot bring it back.
      token
      |> post_observation(
        switch_report([switch("10.0.0.1", "SER-2")],
          observed_at: "2026-08-13T11:00:00Z",
          complete: true
        )
      )
      |> valid_api_response(202)

      token
      |> post_observation(
        switch_report([switch("10.0.0.1", "SER-1")], observed_at: "2026-08-13T10:00:00Z")
      )
      |> valid_api_response(202)

      old = Enum.find(Collectors.list_target_resources(scope, stream.id), &(&1.id == old.id))
      refute present?(old)
      assert inventory_current(scope, old.resource_id) == "false"

      # A newer report of it is current again.
      token
      |> post_observation(
        switch_report([switch("10.0.0.1", "SER-1")], observed_at: "2026-08-13T12:00:00Z")
      )
      |> valid_api_response(202)

      old = Enum.find(Collectors.list_target_resources(scope, stream.id), &(&1.id == old.id))
      assert present?(old)
      assert inventory_current(scope, old.resource_id) == "true"
    end

    test "a late report through a target whose complete report lacked it stays withdrawn", %{
      scope: scope,
      token: token
    } do
      a = %{"address" => "10.0.0.1", "status" => "reachable"}
      b = %{"address" => "10.0.0.2", "status" => "reachable"}

      token
      |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
      |> valid_api_response(202)

      token
      |> post_observation(
        switch_report([], targets: [a, b], complete: true, observed_at: "2026-08-13T09:00:00Z")
      )
      |> valid_api_response(202)

      # Queued from before that complete report, which reached the target and
      # did not contain the switch.
      token
      |> post_observation(
        switch_report([switch("10.0.0.2", "SER-1")], observed_at: "2026-08-13T08:00:00Z")
      )
      |> valid_api_response(202)

      [stream] = Collectors.list_streams(scope)
      members = Collectors.list_target_resources(scope, stream.id)
      assert length(members) == 2
      refute Enum.any?(members, &present?/1)
      assert inventory_current(scope, hd(members).resource_id) == "false"
    end

    for order <- [:old_first, :new_first] do
      test "a switch that moved between targets stays current (#{order})", %{
        scope: scope,
        token: token
      } do
        a = %{"address" => "10.0.0.1", "status" => "reachable"}
        b = %{"address" => "10.0.0.2", "status" => "reachable"}

        token
        |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
        |> valid_api_response(202)

        targets = if unquote(order) == :old_first, do: [a, b], else: [b, a]

        token
        |> post_observation(
          switch_report([switch("10.0.0.2", "SER-1")],
            targets: targets,
            complete: true,
            observed_at: "2026-08-13T09:00:00Z"
          )
        )
        |> valid_api_response(202)

        [stream] = Collectors.list_streams(scope)
        members = Collectors.list_target_resources(scope, stream.id)
        by_target = Map.new(members, &{&1.target.key, &1})

        refute present?(by_target["10.0.0.1"])
        assert present?(by_target["10.0.0.2"])
        assert inventory_current(scope, by_target["10.0.0.2"].resource_id) == "true"
      end
    end

    for order <- [:complete_first, :report_first] do
      test "a complete report wins a tie with a report of the same time (#{order})", %{
        scope: scope,
        token: token
      } do
        token
        |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
        |> valid_api_response(202)

        same_time = "2026-08-13T09:00:00Z"
        complete = switch_report([], complete: true, observed_at: same_time)
        partial = switch_report([switch("10.0.0.1", "SER-1")], observed_at: same_time)

        reports =
          if unquote(order) == :complete_first,
            do: [complete, partial],
            else: [partial, complete]

        for report <- reports do
          token |> post_observation(report) |> valid_api_response(202)
        end

        [stream] = Collectors.list_streams(scope)
        [member] = Collectors.list_target_resources(scope, stream.id)
        refute present?(member)
        assert inventory_current(scope, member.resource_id) == "false"

        # Neither another report of that time nor a retry of the partial one
        # makes it current again.
        token |> post_observation(partial_again(partial)) |> valid_api_response(202)

        partial_id = Repo.get_by!(Observation, idempotency_key: partial["observation_id"]).id
        [derived] = Inventory.list_derived_observations(scope, partial_id)
        assert {:ok, _resource, false} = Reconciler.reconcile(scope, derived)

        [member] = Collectors.list_target_resources(scope, stream.id)
        refute present?(member)
        assert inventory_current(scope, member.resource_id) == "false"

        # A retry of what a snapshot did contain stays current.
        included =
          switch_report([switch("10.0.0.1", "SER-1")],
            complete: true,
            observed_at: "2026-08-13T10:00:00Z"
          )

        assert %{"observation" => %{"id" => included_id}} =
                 token |> post_observation(included) |> valid_api_response(202)

        [derived] = Inventory.list_derived_observations(scope, included_id)
        assert {:ok, _resource, false} = Reconciler.reconcile(scope, derived)
        assert inventory_current(scope, member.resource_id) == "true"
      end
    end

    for order <- [:claim_first, :claim_late, :snapshot_first] do
      test "another target's claim keeps a withdrawn switch current (#{order})", %{
        scope: scope,
        token: token
      } do
        a = %{"address" => "10.0.0.1", "status" => "reachable"}
        claim = switch_report([switch("10.0.0.2", "SER-1")], observed_at: "2026-08-13T07:00:00Z")

        reports = [
          switch_report([switch("10.0.0.1", "SER-1")], observed_at: "2026-08-13T08:00:00Z"),
          switch_report([], targets: [a], complete: true, observed_at: "2026-08-13T09:00:00Z")
        ]

        # Delivered snapshot first, the switch is found only by superseded
        # evidence before the other target's claim arrives.
        reports =
          case unquote(order) do
            :claim_first -> [claim | reports]
            :claim_late -> reports ++ [claim]
            :snapshot_first -> Enum.reverse(reports) ++ [claim]
          end

        for report <- reports do
          token |> post_observation(report) |> valid_api_response(202)
        end

        [stream] = Collectors.list_streams(scope)

        by_target =
          Map.new(Collectors.list_target_resources(scope, stream.id), &{&1.target.key, &1})

        refute present?(by_target["10.0.0.1"])
        assert present?(by_target["10.0.0.2"])
        assert inventory_current(scope, by_target["10.0.0.2"].resource_id) == "true"
      end
    end

    for order <- [:withdrawn_first, :snapshot_first] do
      test "a host agent's late report keeps a withdrawn VM current (#{order})", %{
        scope: scope,
        token: token
      } do
        uuid = "4c4c4544-0000-1111-2222-333344445555"

        reports = [
          hypervisor_report([vm(uuid)], observed_at: "2026-08-13T08:00:00Z"),
          hypervisor_report([], complete: true, observed_at: "2026-08-13T09:00:00Z")
        ]

        reports = if unquote(order) == :snapshot_first, do: Enum.reverse(reports), else: reports

        for report <- reports do
          token |> post_observation(report) |> valid_api_response(202)
        end

        [stream] = Collectors.list_streams(scope)
        [member] = Collectors.list_target_resources(scope, stream.id)
        refute present?(member)
        refute inventory_current(scope, member.resource_id) == "true"

        assert %{"reconciliation" => %{"matched_resource_id" => resource_id}} =
                 token
                 |> post_observation(
                   host_report(dmi_uuid: uuid, observed_at: "2026-08-13T07:00:00Z")
                 )
                 |> valid_api_response(202)

        assert resource_id == member.resource_id
        assert inventory_current(scope, resource_id) == "true"
      end
    end

    test "a resource another source still reports stays current when withdrawn", %{
      scope: scope,
      token: token
    } do
      uuid = "4c4c4544-0000-1111-2222-333344445555"
      token |> post_observation(host_report(dmi_uuid: uuid)) |> valid_api_response(202)
      token |> post_observation(hypervisor_report([vm(uuid)])) |> valid_api_response(202)

      token
      |> post_observation(
        hypervisor_report([], complete: true, observed_at: "2026-08-13T09:00:00Z")
      )
      |> valid_api_response(202)

      [stream] = Collectors.list_streams(scope)
      [member] = Collectors.list_target_resources(scope, stream.id)
      refute present?(member)
      assert inventory_current(scope, member.resource_id) == "true"
    end

    test "a late claim leaves a stale resource stale", %{scope: scope, token: token} do
      %{"reconciliation" => %{"resources" => [%{"resource_id" => switch_id}]}} =
        token
        |> post_observation(
          switch_report([switch("10.0.0.1", "SER-1")], observed_at: "2026-08-13T09:00:00Z")
        )
        |> valid_api_response(202)

      {:ok, _condition} = Inventory.mark_resource_stale(scope, switch_id)

      # Another poller's report from before the switch went stale arrives late.
      token
      |> post_observation(
        switch_report([switch("10.0.0.1", "SER-1")],
          collector_id: "edge-switches",
          observed_at: "2026-08-13T08:00:00Z"
        )
      )
      |> valid_api_response(202)

      assert %{status: "false", reason: "Stale"} =
               scope
               |> Inventory.list_resource_conditions(switch_id)
               |> Enum.find(&(&1.type == "InventoryCurrent"))
    end

    test "a failed resource stops its target from withdrawing anything", %{
      scope: scope,
      token: token
    } do
      token
      |> post_observation(switch_report([switch("10.0.0.1", "SER-1")]))
      |> valid_api_response(202)

      # Two existing resources claim the identifiers this switch now reports.
      token
      |> post_observation(switch_report([switch("10.0.0.2", "SER-2")]))
      |> valid_api_response(202)

      ambiguous =
        switch("10.0.0.1", "SER-1")
        |> put_in(["identifiers", "serial_number"], ["SER-1", "SER-2"])

      conn =
        post_observation(
          token,
          switch_report([ambiguous, switch("10.0.0.2", "SER-2")],
            targets: [
              %{"address" => "10.0.0.1", "status" => "reachable"},
              %{"address" => "10.0.0.2", "status" => "reachable"}
            ],
            complete: true,
            observed_at: "2026-08-13T09:00:00Z"
          )
        )

      assert %{
               "reconciliation" => %{
                 "status" => "succeeded",
                 "resources" => [%{"status" => "failed"}, %{"status" => "succeeded"}]
               }
             } = valid_api_response(conn, 202)

      [stream] = Collectors.list_streams(scope)
      assert Enum.all?(Collectors.list_target_resources(scope, stream.id), &present?/1)
    end
  end

  describe "validation" do
    test "rejects malformed scoped reports", %{token: token} do
      cases = [
        {Map.delete(switch_report([switch("10.0.0.1", "SER-1")]), "collector"), "collector"},
        {Map.put(host_report(), "collector", %{"id" => "x", "kind" => "switch_poller"}),
         "collector"},
        {switch_report([switch("10.0.0.1", "SER-1")], collector_id: "-bad"), "collector.id"},
        {switch_report([switch("10.0.0.1", "SER-1")], kind: "vm_provider"), "collector.kind"},
        {switch_report([switch("10.9.9.9", "SER-1")]), "resources.0.target"},
        {switch_report([switch("10.0.0.1", "SER-1")],
           targets: [%{"address" => "10.0.0.1", "status" => "unreachable"}]
         ), "resources.0.target"},
        {switch_report([Map.put(switch("10.0.0.1", "SER-1"), "kind", "vm")]), "resources.0.kind"},
        {switch_report([
           switch("10.0.0.1", nil, hostname: "core1")
         ]), "resources.0.identifiers"},
        {switch_report([],
           targets: [
             %{"address" => "10.0.0.1", "status" => "reachable"},
             %{"address" => "10.0.0.1", "status" => "reachable"}
           ]
         ), "targets.1.address"},
        {hypervisor_report([vm("VM-1")], status: "unreachable"), "resources.0"},
        {Map.put(switch_report([]), "scope", "galaxy"), "scope"},
        {switch_report([Map.put(switch("10.0.0.1", "SER-1"), "domain", domain())]),
         "resources.0.domain"},
        {hypervisor_report([Map.put(vm("VM-1"), "domain", Map.delete(domain(), "state"))]),
         "resources.0.domain.state"},
        {hypervisor_report([Map.put(vm("VM-1"), "domain", %{domain() | "state" => "asleep"})]),
         "resources.0.domain.state"},
        {hypervisor_report([
           Map.put(vm("VM-1"), "domain", %{domain() | "interfaces" => [%{"type" => "bridge"}]})
         ]), "resources.0.domain.interfaces.0.mac_address"},
        {hypervisor_report([
           Map.put(vm("VM-1"), "domain", %{domain() | "disks" => [%{"bus" => "virtio"}]})
         ]), "resources.0.domain.disks.0.target"}
      ]

      for {payload, path} <- cases do
        conn = post_observation(token, payload)
        assert %{"errors" => errors} = valid_api_response(conn, 422)
        assert Enum.any?(errors, &(&1["path"] == path)), "expected #{path} in #{inspect(errors)}"
      end
    end
  end

  describe "libvirt domains (RFD 11 phase 3)" do
    test "a hypervisor report carries each VM's domain", %{token: token} do
      report =
        post_observation(
          token,
          hypervisor_report([
            Map.put(vm("6a4f3c2e-1b2d-4e5f-8a9b-0c1d2e3f4a5b"), "domain", domain())
          ])
        )

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => vm_id}]}} =
               valid_api_response(report, 202)

      # With no hostname to go on, the VM is named after its domain.
      assert Repo.get!(Inventory.Resource, vm_id).name == "web-1"
    end
  end

  describe "switch pollers (RFD 11 phase 2)" do
    # Written by the agent's mappers from recorded switches (agent/src/snmp/mod.rs and
    # agent/src/gnmi/openconfig.rs), so the server's cross-field rules, which the OpenAPI
    # schema cannot state, check real output.
    for {mapper, fixture} <- [
          {"SNMP", "recorded_switch.json"},
          {"gNMI", "recorded_gnmi_switch.json"}
        ] do
      @fixture fixture
      test "accepts a switch as the agent's #{mapper} mapper reports it", %{
        scope: scope,
        token: token
      } do
        resource =
          "test/fixtures/collectors/#{@fixture}" |> File.read!() |> Jason.decode!()

        assert %{
                 "reconciliation" => %{
                   "resources" => [%{"status" => "succeeded", "resource_id" => id}]
                 }
               } =
                 token
                 |> post_observation(switch_report([resource], complete: true))
                 |> valid_api_response(202)

        assert Inventory.get_resource!(scope, id).kind == "switch"
      end
    end

    test "two pollers reporting one chassis serial reconcile to one switch", %{
      scope: scope,
      token: token
    } do
      first = post_observation(token, switch_report([switch("10.0.0.1", "SER-1")]))

      second =
        post_observation(
          token,
          switch_report([switch("192.0.2.1", "SER-1")], collector_id: "dc2-switches"),
          installation_id: @other_installation_id
        )

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => id}]}} =
               valid_api_response(first, 202)

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => ^id}]}} =
               valid_api_response(second, 202)

      streams = Collectors.list_streams(scope)
      assert length(streams) == 2

      assert [%{id: ^id}] = Enum.filter(Inventory.list_resources(scope), &(&1.kind == "switch"))
    end

    test "a report without interfaces preserves the switch's last interface state", %{
      scope: scope,
      token: token
    } do
      switch =
        switch("10.0.0.1", "SER-1",
          interfaces: [%{"name" => "Ethernet1", "kind" => "ethernet", "status" => "up"}]
        )

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => id}]}} =
               token
               |> post_observation(switch_report([switch], complete: true))
               |> valid_api_response(202)

      identity_only = Map.delete(switch, "interfaces")

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => ^id}]}} =
               token
               |> post_observation(switch_report([identity_only], complete: true))
               |> valid_api_response(202)

      assert [%{name: "Ethernet1", status: "up"}] = Inventory.list_interfaces(scope, id)
    end

    test "a switch's LLDP neighbors and VLANs become topology evidence", %{
      scope: scope,
      token: token
    } do
      uplink = %{
        "name" => "Te1/1/1",
        "kind" => "ethernet",
        "status" => "up",
        "mac_address" => "00:1b:21:aa:bb:31",
        "vlan_mode" => "trunk",
        "vlans" => [
          %{"vid" => 10, "tagging_mode" => "untagged"},
          %{"vid" => 20, "tagging_mode" => "tagged"}
        ],
        "neighbors" => [
          %{
            "protocol" => "lldp",
            "remote_chassis_id" => "00:1c:73:01:02:03",
            "remote_chassis_id_kind" => "mac_address",
            "remote_port_id" => "Ethernet1/49",
            "remote_port_id_kind" => "name",
            "remote_system_name" => "spine-01",
            "ttl_seconds" => 2_700
          }
        ]
      }

      report =
        [switch("10.0.0.1", "SER-1", interfaces: [uplink])]
        |> switch_report(complete: true)
        |> Map.put("section_completeness", %{
          "interface_vlans" => true,
          "interface_neighbors" => true
        })

      assert %{"reconciliation" => %{"resources" => [%{"resource_id" => id}]}} =
               token |> post_observation(report) |> valid_api_response(202)

      [interface] = Inventory.list_interfaces(scope, id)
      assert interface.name == "Te1/1/1"

      assert [evidence] = Renga.Topology.list_interface_neighbor_evidence(scope, interface.id)
      assert evidence.remote_system_name == "spine-01"

      # Memberships resolve once the stream is mapped to a VLAN group; the evidence is kept now.
      vids =
        scope
        |> Renga.Topology.list_interface_vlan_evidence(interface.id)
        |> Enum.map(&{&1.vid, &1.tagging_mode})
        |> Enum.sort()

      assert vids == [{10, "untagged"}, {20, "tagged"}]
    end
  end

  defp post_observation(token, payload, opts \\ []) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header(
      "x-renga-installation-id",
      Keyword.get(opts, :installation_id, @installation_id)
    )
    |> post(~p"/api/v1/observations", payload)
  end

  defp host_report(opts \\ []) do
    identifiers =
      %{"machine_id" => "machine-#{System.unique_integer([:positive])}"}
      |> maybe_put("dmi_uuid", opts[:dmi_uuid])
      |> maybe_put("hostname", opts[:hostname])

    interfaces =
      case opts[:mac] do
        nil -> []
        mac -> [%{"name" => "eth0", "kind" => "ethernet", "mac_address" => mac}]
      end

    %{
      "observation_id" => "host-#{System.unique_integer([:positive])}",
      "observed_at" => Keyword.get(opts, :observed_at, "2026-08-13T07:30:00Z"),
      "resources" => [
        %{
          "kind" => "server",
          "identifiers" => identifiers,
          "attributes" => %{},
          "interfaces" => interfaces
        }
      ]
    }
  end

  defp switch_report(resources, opts \\ []) do
    targets =
      Keyword.get_lazy(opts, :targets, fn ->
        resources
        |> Enum.map(& &1["target"])
        |> Enum.uniq()
        |> Enum.reject(&(&1 == "10.9.9.9"))
        |> Enum.map(&%{"address" => &1, "status" => "reachable"})
        |> case do
          [] -> [%{"address" => "10.0.0.1", "status" => "reachable"}]
          targets -> targets
        end
      end)

    %{
      "observation_id" =>
        Keyword.get(opts, :observation_id, "poll-#{System.unique_integer([:positive])}"),
      "observed_at" => Keyword.get(opts, :observed_at, "2026-08-13T07:30:00Z"),
      "scope" => "targets",
      "collector" => %{
        "id" => Keyword.get(opts, :collector_id, "core-switches"),
        "kind" => Keyword.get(opts, :kind, "switch_poller")
      },
      "targets" => targets,
      "complete" => Keyword.get(opts, :complete, false),
      "resources" => resources
    }
  end

  defp hypervisor_report(resources, opts \\ []) do
    %{
      "observation_id" => "libvirt-#{System.unique_integer([:positive])}",
      "observed_at" => Keyword.get(opts, :observed_at, "2026-08-13T07:30:00Z"),
      "scope" => "hypervisor",
      "collector" => %{
        "id" => Keyword.get(opts, :collector_id, "local-libvirt"),
        "kind" => "vm_provider"
      },
      "hypervisor" => %{"id" => "hv-1", "status" => Keyword.get(opts, :status, "reachable")},
      "complete" => Keyword.get(opts, :complete, false),
      "resources" => resources
    }
  end

  defp switch(target, serial, opts \\ []) do
    identifiers =
      %{}
      |> maybe_put("serial_number", serial)
      |> maybe_put("hostname", opts[:hostname])

    %{
      "kind" => "switch",
      "target" => target,
      "identifiers" => identifiers,
      "attributes" => %{"model" => "S5248F"},
      "interfaces" => Keyword.get(opts, :interfaces, [])
    }
  end

  defp vm(uuid) do
    %{"kind" => "vm", "identifiers" => %{"dmi_uuid" => uuid}, "interfaces" => []}
  end

  defp partial_again(report),
    do: Map.put(report, "observation_id", "poll-#{System.unique_integer([:positive])}")

  defp domain do
    %{
      "name" => "web-1",
      "state" => "running",
      "persistent" => true,
      "vcpus" => 2,
      "memory_mib" => 2048,
      "disks" => [
        %{
          "target" => "vda",
          "device" => "disk",
          "bus" => "virtio",
          "source" => "/var/lib/web-1.qcow2"
        }
      ],
      "interfaces" => [
        %{
          "mac_address" => "52:54:00:12:34:56",
          "type" => "bridge",
          "source" => "br0",
          "model" => "virtio"
        }
      ]
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(member), do: CollectorTargetResource.present?(member)

  defp serial(scope, member) do
    scope
    |> Inventory.list_resource_identifiers(member.resource_id)
    |> Enum.find_value(&if(&1.kind == "serial_number", do: &1.value))
  end

  defp inventory_current(scope, resource_id) do
    scope
    |> Inventory.list_resource_conditions(resource_id)
    |> Enum.find_value(&if(&1.type == "InventoryCurrent", do: &1.status))
  end
end
