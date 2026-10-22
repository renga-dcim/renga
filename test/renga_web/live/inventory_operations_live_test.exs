defmodule RengaWeb.InventoryOperationsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.AgentLease
  alias Renga.Repo

  @installation_id "67e55044-10b1-426f-9247-bb680e5fe0c8"

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Existing fleet"})
    {:ok, authenticated_key} = Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(scope, authenticated_key, @installation_id, %{
        capabilities: ["host.inventory"],
        metadata: %{"agent_version" => "0.1.0"}
      })

    source = Inventory.get_source!(scope, agent.source_id)

    %{
      conn: conn,
      scope: scope,
      membership: membership,
      key: key,
      source: source,
      agent: agent
    }
  end

  test "shows organization keys separately from automatically discovered collectors", %{
    conn: conn,
    key: key,
    source: source
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    assert has_element?(view, "#intake-key-management")
    assert has_element?(view, "#intake-key-#{key.id}", "Existing fleet")
    assert has_element?(view, "#collector-list")
    assert has_element?(view, "#collector-#{source.id}", "Connected")
    assert has_element?(view, "#collector-#{source.id}", "67e55044…e0c8")
    refute has_element?(view, "#collector-#{source.id}", "Credential")
    refute has_element?(view, "[id^='rotate-collector-']")
  end

  test "shows the job capabilities each collector accepts", %{
    conn: conn,
    scope: scope,
    source: source
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, "#collector-jobs-#{source.id}", "None enabled")

    {:ok, key} = Inventory.create_intake_api_key(scope, %{name: "Jobs fleet"})
    {:ok, authenticated_key} = key |> elem(1) |> Inventory.authenticate_intake_api_key()

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(scope, authenticated_key, Ecto.UUID.generate(), %{
        capabilities: ["host.inventory", "inventory.collect@1", "vendor.thing@2"]
      })

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    jobs = "#collector-jobs-#{agent.source_id}"
    assert has_element?(view, jobs, "inventory.collect@1")
    refute has_element?(view, jobs, "host.inventory")
    assert has_element?(view, "#{jobs}-list-list", "Collect inventory · observe")
    assert has_element?(view, "#{jobs}-list-list", "Unknown to Renga")
  end

  test "shows contact, lease, accepted, and reconciled as separate clocks", %{
    conn: conn,
    scope: scope,
    source: source,
    agent: agent
  } do
    Repo.update_all(from(a in Renga.Inventory.Agent, where: a.id == ^agent.id),
      set: [last_contacted_at: ~U[2026-10-10 08:00:00.000000Z]]
    )

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    assert has_element?(
             view,
             "#collector-connection-#{source.id}",
             "contact 2026-10-10 08:00 UTC"
           )

    assert has_element?(view, "#collector-connection-#{source.id}", "expires")
    assert has_element?(view, "#collector-inventory-#{source.id}", "No inventory yet")

    # Accepted but not yet reconciled: the reconciled clock has not moved.
    {:ok, first} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "clocks-first",
        observed_at: ~U[2026-10-09 12:34:00.000Z],
        payload: %{"resources" => []}
      })

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    inventory = "#collector-inventory-#{source.id}"
    assert has_element?(view, inventory, "accepted")
    assert has_element?(view, inventory, "reconciled Never")
    assert has_element?(view, inventory, "Latest report not reconciled yet")

    reconcile(scope, first, "succeeded")
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, inventory, "reconciled 2026-10-09 12:34 UTC")
    refute has_element?(view, inventory, "Latest report")

    # A newer report that fails keeps the reconciled clock where it was.
    {:ok, second} =
      Inventory.create_observation(scope, source.id, %{
        idempotency_key: "clocks-second",
        observed_at: ~U[2026-10-09 13:00:00.000Z],
        payload: %{"resources" => []}
      })

    reconcile(scope, second, "failed")
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, inventory, "reconciled 2026-10-09 12:34 UTC")
    assert has_element?(view, inventory, "Latest report failed to reconcile")
  end

  test "shows each collector's undelivered observation backlog", %{
    conn: conn,
    source: source,
    agent: agent
  } do
    queue_cell = "#collector-queue-#{source.id}"

    # An agent that predates the queue reports nothing.
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, queue_cell, "Not reported")

    report_queue(agent, %{"entries" => 0, "bytes" => 0, "oldest_age_seconds" => nil})
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, queue_cell, "Empty")
    refute has_element?(view, queue_cell, "dropped")

    report_queue(agent, %{
      "entries" => 14,
      "bytes" => 1_250_000,
      "oldest_age_seconds" => 3 * 3_600 + 59,
      "dropped_for_space" => 2,
      "rejected" => 1
    })

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, queue_cell, "14 undelivered")
    assert has_element?(view, queue_cell, "oldest 3h · 1.3 MB")

    assert has_element?(view, queue_cell, "3 dropped since restart")
    assert has_element?(view, queue_cell, "(2 to make room, 1 rejected by Renga)")
  end

  test "shows the telemetry queue only for agents that report one", %{
    conn: conn,
    source: source,
    agent: agent
  } do
    telemetry_cell = "#collector-telemetry-queue-#{source.id}"
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    refute has_element?(view, telemetry_cell)

    report_queue(agent, "telemetry_queue", %{
      "entries" => 3,
      "bytes" => 4_000,
      "oldest_age_seconds" => 180,
      "dropped_for_space" => 4,
      "expired" => 1,
      "dropped_earliest_age_seconds" => 2 * 86_400,
      "dropped_latest_age_seconds" => 3 * 3_600
    })

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, telemetry_cell, "3 undelivered")
    assert has_element?(view, "#collector-queue-#{source.id}", "Not reported")

    assert has_element?(view, telemetry_cell, "5 dropped since restart")

    assert has_element?(
             view,
             telemetry_cell,
             "(4 to make room, 1 after a day; queued 2d to 3h before the last check-in)"
           )
  end

  test "shows which power sources each agent can read and what would enable the rest", %{
    conn: conn,
    source: source,
    agent: agent
  } do
    cell = "#collector-power-#{source.id}"
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    refute has_element?(view, cell)

    agent
    |> Ecto.Changeset.change(
      metadata:
        Map.put(agent.metadata, "power_sources", [
          %{"source" => "hwmon", "status" => "not_present"}
        ])
    )
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, "#{cell}-0", "Not present")

    assert view
           |> element("#{cell}-0")
           |> render() =~ "ipmi_exporter"

    agent
    |> Ecto.Changeset.change(
      metadata:
        Map.put(agent.metadata, "power_sources", [
          %{"source" => "hwmon", "status" => "available"},
          %{"source" => "http://127.0.0.1:9100/metrics", "status" => "not_present"},
          %{"source" => "power_poller/rack-pdus", "status" => "not_present"},
          %{"source" => "bmc_power/rack-bmcs", "status" => "not_present"}
        ])
    )
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, "#{cell}-0", "Available")
    assert has_element?(view, "#{cell}-1", "http://127.0.0.1:9100/metrics")
    assert view |> element("#{cell}-1") |> render() =~ "serves no power metric"
    assert view |> element("#{cell}-2") |> render() =~ "Raritan PDU2-MIB"
    assert view |> element("#{cell}-3") |> render() =~ "the Power resource the agent reads"
  end

  test "shows whether each collector's host can use osquery", %{
    conn: conn,
    source: source,
    agent: agent
  } do
    cell = "#collector-osquery-#{source.id}"

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, cell, "Not reported")

    for {osquery, texts} <- [
          {%{"status" => "available", "version" => "5.12.1"}, ["Available", "5.12.1"]},
          {%{"status" => "not_permitted"}, ["Not permitted"]},
          {%{"status" => "not_present"}, ["Not running"]},
          {%{"status" => "bogus"}, ["Not reported"]}
        ] do
      agent
      |> Ecto.Changeset.change(metadata: %{"query_backends" => %{"osquery" => osquery}})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      for text <- texts, do: assert(has_element?(view, cell, text))
    end
  end

  test "malformed legacy queue metadata is not reported rather than crashing", %{
    conn: conn,
    source: source,
    agent: agent
  } do
    valid = %{
      "entries" => 1,
      "bytes" => 100,
      "oldest_age_seconds" => 5,
      "dropped_for_space" => 0,
      "expired" => 0,
      "rejected" => 0,
      "unreadable" => 0
    }

    for queue <- [
          %{},
          %{"dropped_for_space" => "1"},
          [],
          Map.delete(valid, "oldest_age_seconds"),
          %{valid | "rejected" => "1"},
          %{valid | "entries" => 9_007_199_254_740_992},
          %{valid | "oldest_age_seconds" => -1}
        ] do
      agent
      |> Ecto.Changeset.change(metadata: %{"observation_queue" => queue})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      assert has_element?(view, "#collector-queue-#{source.id}", "Not reported")
      refute has_element?(view, "#collector-queue-#{source.id}", "Empty")
    end
  end

  test "creates and reveals an intake key once", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")

    view |> element("#new-intake-key-button") |> render_click()
    assert has_element?(view, "#new-intake-key-panel")

    view
    |> form("#new-intake-key-form", intake_api_key: %{name: "Replacement fleet"})
    |> render_submit()

    assert has_element?(view, "#intake-key-credentials")
    assert has_element?(view, "#issued-intake-key", "renga_intake_")

    assert has_element?(
             view,
             "#copy-intake-key[phx-hook='CopyToClipboard'][data-copy-target='#issued-intake-key'][data-copy-status='#copy-intake-key-status']"
           )

    assert has_element?(
             view,
             "#copy-intake-key-status[role='status'][aria-live='polite'][aria-atomic='true']"
           )

    assert has_element?(
             view,
             "#intake-key-credentials code",
             ~s(renga_url = "http://localhost:4002")
           )

    assert has_element?(view, "#intake-key-credentials code", ~s(intake_api_key = "renga_intake_))
    refute has_element?(view, "#intake-key-credentials code", "@issued_token")

    assert has_element?(
             view,
             "#intake-key-credentials code > span:first-child",
             ~s(renga_url = "http://localhost:4002")
           )

    assert has_element?(
             view,
             "#intake-key-credentials code > span:nth-child(2)",
             ~s(intake_api_key = "renga_intake_)
           )

    assert has_element?(view, "#intake-api-keys", "Replacement fleet")
    assert Enum.any?(Inventory.list_intake_api_keys(scope), &(&1.name == "Replacement fleet"))

    view |> element("#finish-intake-key-setup") |> render_click()
    refute has_element?(view, "#issued-intake-key")
  end

  test "revokes one key without deleting collector provenance", %{
    conn: conn,
    scope: scope,
    key: key,
    source: source,
    agent: agent
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    assert has_element?(view, "#revoke-intake-key-#{key.id}-dialog [role='alertdialog']")
    view |> element("#revoke-intake-key-#{key.id}-dialog-confirm") |> render_click()

    assert has_element?(view, "#intake-key-#{key.id}", "Revoked")
    refute has_element?(view, "#revoke-intake-key-#{key.id}")
    assert Inventory.get_source!(scope, source.id)
    assert Inventory.get_agent!(scope, agent.id)
  end

  test "viewer sees operations but cannot forge key mutations" do
    viewer = user_fixture()
    organization = organization_fixture(%{name: "Read only operations"})
    organization_membership_fixture(viewer, organization, %{role: "viewer"})
    scope = Accounts.scope_for_user(viewer, organization.id)

    conn =
      build_conn()
      |> log_in_user(viewer)
      |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    refute has_element?(view, "#new-intake-key-button")

    render_hook(view, "create_intake_key", %{"intake_api_key" => %{"name" => "Forged"}})
    assert Inventory.list_intake_api_keys(scope) == []
  end

  test "a stale admin scope cannot create or revoke keys after role downgrade", %{
    conn: conn,
    scope: scope,
    membership: membership,
    key: key
  } do
    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    {:ok, _membership} = Accounts.update_organization_membership(membership, %{role: "viewer"})

    render_hook(view, "create_intake_key", %{"intake_api_key" => %{"name" => "Forged"}})
    render_hook(view, "revoke_intake_key", %{"id" => key.id})

    assert Enum.map(Inventory.list_intake_api_keys(scope), &{&1.name, &1.status}) == [
             {"Existing fleet", "active"}
           ]
  end

  test "disconnected filter follows lease state", %{conn: conn, source: source, agent: agent} do
    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(
      from(lease in AgentLease, where: lease.agent_id == ^agent.id),
      set: [renewed_at: DateTime.add(expired_at, -90, :second), expires_at: expired_at]
    )

    {:ok, view, _html} = live(conn, ~p"/settings/collectors?disconnected=true")
    assert has_element?(view, "#collector-#{source.id}", "Disconnected")
  end

  describe "poller targets" do
    test "lists each stream's targets, unreachable ones first", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      refute has_element?(view, "#collector-targets")

      {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Pollers"})

      post_report(token, %{
        "scope" => "targets",
        "collector" => %{"id" => "core-switches", "kind" => "switch_poller"},
        "targets" => [
          %{"address" => "10.0.0.1", "status" => "reachable"},
          %{"address" => "10.0.0.2", "status" => "unreachable", "error" => "timeout"}
        ],
        "complete" => true,
        "resources" => [
          %{
            "kind" => "switch",
            "target" => "10.0.0.1",
            "identifiers" => %{"serial_number" => "SER-1"},
            "attributes" => %{},
            "interfaces" => []
          }
        ]
      })

      post_report(token, %{
        "scope" => "hypervisor",
        "collector" => %{"id" => "local-libvirt", "kind" => "vm_provider"},
        "hypervisor" => %{
          "id" => "qemu+ssh://root:secret@hv-1/system?token=hidden#private",
          "status" => "unreachable",
          "error" =>
            "Failed to connect to qemu+ssh://root:secret@hv-1/system?token=hidden#private"
        },
        "complete" => true,
        "resources" => []
      })

      [switches, libvirt] =
        scope
        |> Renga.Inventory.Collectors.list_stream_targets()
        |> Enum.sort_by(fn {stream, _targets} -> stream.collector_id end)

      {_stream, [{down, 0}, {up, 1}]} = switches
      {_stream, [{hypervisor, 0}]} = libvirt
      assert down.key == "10.0.0.2"

      {:ok, view, html} = live(conn, ~p"/settings/collectors")

      assert has_element?(view, "#poller-targets", "core-switches · Switch poller")
      assert has_element?(view, "#poller-target-#{up.id}", "10.0.0.1")
      assert has_element?(view, "#poller-target-state-#{up.id}", "Reachable")
      assert has_element?(view, "#poller-target-resources-#{up.id}", "1")
      assert has_element?(view, "#poller-target-state-#{down.id}", "Unreachable")
      assert has_element?(view, "#poller-target-state-#{down.id}", "Connection failed")
      assert has_element?(view, "#poller-target-#{down.id}", "Never")

      # Unreachable targets lead their stream.
      assert :binary.match(html, "poller-target-#{down.id}") <
               :binary.match(html, "poller-target-#{up.id}")

      # Neither a target URI nor an unrestricted collector diagnostic can
      # disclose credentials someone put in the collector configuration.
      assert has_element?(view, "#poller-targets", "local-libvirt · Hypervisor")
      assert has_element?(view, "#poller-target-#{hypervisor.id}", "qemu+ssh://hv-1/system")
      assert has_element?(view, "#poller-target-state-#{hypervisor.id}", "Connection failed")
      refute html =~ "root:secret"
      refute html =~ "token=hidden"
      refute html =~ "#private"
    end
  end

  test "does not display keys or collectors from another organization", %{conn: conn} do
    other_user = user_fixture()
    organization = organization_fixture(%{name: "Other operations"})
    organization_membership_fixture(other_user, organization, %{role: "admin"})
    other_scope = Accounts.scope_for_user(other_user, organization.id)
    {:ok, {foreign_key, _token}} = Inventory.create_intake_api_key(other_scope, %{name: "Secret"})

    {:ok, view, _html} = live(conn, ~p"/settings/collectors")
    refute has_element?(view, "#intake-key-#{foreign_key.id}")
    refute has_element?(view, "#intake-api-keys", "Secret")
  end

  # Stores a queue report as the agent's latest check-in would, defaulting the
  # counters a test does not care about to zero.
  defp report_queue(agent, name \\ "observation_queue", queue) do
    queue =
      Map.merge(
        %{"dropped_for_space" => 0, "expired" => 0, "rejected" => 0, "unreadable" => 0},
        queue
      )

    agent
    |> Ecto.Changeset.change(metadata: Map.put(agent.metadata, name, queue))
    |> Repo.update!()
  end

  defp reconcile(scope, observation, status) do
    now = Renga.Time.utc_now_ms()

    {:ok, _} =
      Inventory.create_observation_reconciliation(scope, observation.id, %{
        status: status,
        attempt: 1,
        started_at: now,
        completed_at: now
      })
  end

  describe "installation keys" do
    defp present_key(agent, public_key) do
      {:ok, key} =
        Repo.transaction(fn ->
          Renga.Inventory.InstallationKeys.present!(
            agent,
            %{algorithm: "ed25519", public_key: public_key},
            Renga.Time.utc_now_ms()
          )
        end)

      key
    end

    test "approves a pending key after showing its fingerprint", %{
      conn: conn,
      agent: agent,
      source: source
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      assert has_element?(view, "#collector-key-#{source.id}", "Not presented")

      key = present_key(agent, :crypto.strong_rand_bytes(32))
      {:ok, view, _html} = live(conn, ~p"/settings/collectors")

      assert has_element?(view, "#collector-key-#{source.id}", "Pending")
      assert has_element?(view, "#approve-key-#{key.id}", key.fingerprint)
      assert has_element?(view, "#pending-key-#{key.id}", source.name)
      assert has_element?(view, "#pending-key-#{key.id}-approve")

      render_click(view, "approve_installation_key", %{id: key.id, fingerprint: key.fingerprint})

      assert has_element?(view, "#collector-key-#{source.id}", "Approved")
      refute has_element?(view, "#approve-key-#{key.id}-button")
      refute has_element?(view, "#pending-installation-keys")
    end

    test "refuses a key that changed after the page loaded", %{conn: conn, agent: agent} do
      key = present_key(agent, :crypto.strong_rand_bytes(32))
      {:ok, view, _html} = live(conn, ~p"/settings/collectors")
      _replacement = present_key(agent, :crypto.strong_rand_bytes(32))

      html =
        render_click(view, "approve_installation_key", %{id: key.id, fingerprint: key.fingerprint})

      assert html =~ "The installation presented a different key"
    end

    test "members see key state without approving", %{
      agent: agent,
      source: source,
      scope: scope
    } do
      member = user_fixture()
      organization_membership_fixture(member, scope.organization, %{role: "member"})

      conn =
        build_conn()
        |> log_in_user(member)
        |> put_session(:current_organization_id, scope.organization_id)

      key = present_key(agent, :crypto.strong_rand_bytes(32))
      {:ok, view, _html} = live(conn, ~p"/settings/collectors")

      assert has_element?(view, "#collector-key-#{source.id}", "Pending")
      refute has_element?(view, "#approve-key-#{key.id}-button")
      assert has_element?(view, "#pending-key-#{key.id}")
      refute has_element?(view, "#pending-key-#{key.id}-approve")
      refute has_element?(view, "#approve-key-#{key.id}")
    end
  end

  defp post_report(token, payload) do
    payload =
      Map.merge(
        %{
          "observation_id" => "poll-#{System.unique_integer([:positive])}",
          "observed_at" => "2026-08-13T07:30:00Z"
        },
        payload
      )

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", @installation_id)
    |> post(~p"/api/v1/observations", payload)
    |> valid_api_response(202)
  end
end
