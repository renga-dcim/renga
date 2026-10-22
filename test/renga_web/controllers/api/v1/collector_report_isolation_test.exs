defmodule RengaWeb.Api.V1.CollectorReportIsolationTest do
  @moduledoc """
  RFD 11: an unexpected failure reconciling one resource of a collector report
  stays with that resource.
  """

  # The trigger below locks resource_identifiers until the test's sandbox
  # transaction ends, which would stall concurrent tests.
  use RengaWeb.ConnCase, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Inventory.CollectorTargetResource
  alias Renga.Inventory.Collectors
  alias Renga.Inventory.Reconciler
  alias Renga.Repo

  setup do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)
    {:ok, {_key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})

    # A database error only these serial numbers hit, rolled back with the test.
    Repo.query!("""
    CREATE FUNCTION pg_temp.fail_boom() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.value LIKE 'SER-BOOM%' AND current_setting('renga.boom', true) IS DISTINCT FROM 'off' THEN RAISE EXCEPTION 'injected failure'; END IF;
      RETURN NEW;
    END $$
    """)

    %{scope: scope, token: token}
  end

  # The canonical identifier is written directly; its claim inside a nested
  # transaction, whose failure aborts the whole enclosing transaction.
  for table <- ~w(resource_identifiers resource_identifier_claims) do
    test "a resource that fails unexpectedly writing #{table} fails alone", %{
      scope: scope,
      token: token
    } do
      Repo.query!("""
      CREATE TRIGGER fail_boom BEFORE INSERT ON #{unquote(table)}
      FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_boom()
      """)

      fails_alone(scope, token)
    end
  end

  describe "while another run of the same report succeeds" do
    setup do
      Repo.query!("""
      CREATE TRIGGER fail_boom BEFORE INSERT ON resource_identifiers
      FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_boom()
      """)

      :ok
    end

    # The run under test fails on SER-BOOM and rolls back; before it records
    # that failure, `other_run` reconciles the same report with the failure
    # gone. The committed success must stand.
    defp racing(other_run) do
      calls = :counters.new(1, [])

      fn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 2 do
          Repo.query!("SELECT set_config('renga.boom', 'off', false)")
          other_run.()
        end

        :ok
      end
    end

    test "a retry keeps the success", %{scope: scope, token: token} do
      %{"observation" => %{"id" => report_id}} =
        post!(token, report([switch("10.0.0.2", "SER-BOOM-2")], complete: false))

      report = Repo.get!(Renga.Inventory.Observation, report_id)
      [derived] = Inventory.list_derived_observations(scope, report.id)
      assert statuses(scope, derived) == ["failed"]

      Reconciler.reconcile(scope, report,
        authorize: racing(fn -> Reconciler.reconcile(scope, report) end)
      )

      assert statuses(scope, derived) == ["failed", "succeeded"]
    end

    test "a first attempt keeps the success", %{scope: scope, token: token} do
      {:ok, intake_scope, installation_id, key} =
        RengaWeb.IntakeAuth.authenticate(token, ["67e55044-10b1-426f-9247-bb680e5fe0c8"])

      payload = report([switch("10.0.0.2", "SER-BOOM-2")], complete: false)

      {:ok, attrs} =
        Renga.Inventory.AgentPayload.validate_observation(payload, %Renga.Inventory.Source{
          kind: "switch_poller"
        })

      {:ok, {_agent, _lease, report, _disposition}} =
        Inventory.ingest_intake_observation(intake_scope, key, installation_id, %{}, attrs)

      [derived] = Inventory.list_derived_observations(scope, report.id)

      Reconciler.reconcile_once(scope, report,
        authorize: racing(fn -> Reconciler.reconcile_once(scope, report) end)
      )

      assert statuses(scope, derived) == ["succeeded"]
    end
  end

  defp statuses(scope, observation) do
    scope
    |> Inventory.list_observation_reconciliations(observation.id)
    |> Enum.map(& &1.status)
  end

  defp fails_alone(scope, token) do
    post!(token, report([switch("10.0.0.2", "SER-1")], complete: false))

    report =
      post!(
        token,
        report(
          [
            switch("10.0.0.1", "SER-BOOM-1"),
            switch("10.0.0.2", "SER-BOOM"),
            switch("10.0.0.3", "SER-3")
          ],
          complete: true,
          observed_at: "2026-08-13T09:00:00Z"
        )
      )

    assert %{
             "status" => "succeeded",
             "resources" => [
               %{"status" => "failed", "errors" => %{"processing" => "projection_failed"}},
               %{"status" => "failed", "errors" => %{"processing" => "projection_failed"}},
               %{"status" => "succeeded", "resource_id" => resource_id}
             ]
           } = report["reconciliation"]

    assert %{} = Inventory.get_resource!(scope, resource_id)

    # Nothing the failed resource wrote survives, and its unknown contents stop
    # the complete report from withdrawing the switch it did not mention.
    assert Repo.aggregate(
             from(i in "resource_identifiers", where: like(i.value, "SER-BOOM%")),
             :count
           ) == 0

    [stream] = Collectors.list_streams(scope)
    members = Collectors.list_target_resources(scope, stream.id)
    assert length(members) == 2
    assert Enum.all?(members, &CollectorTargetResource.present?/1)
  end

  defp post!(token, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", "67e55044-10b1-426f-9247-bb680e5fe0c8")
    |> post(~p"/api/v1/observations", payload)
    |> valid_api_response(202)
  end

  defp report(resources, opts) do
    %{
      "observation_id" => "poll-#{System.unique_integer([:positive])}",
      "observed_at" => Keyword.get(opts, :observed_at, "2026-08-13T07:30:00Z"),
      "scope" => "targets",
      "collector" => %{"id" => "core-switches", "kind" => "switch_poller"},
      "targets" =>
        for(
          target <- ~w(10.0.0.1 10.0.0.2 10.0.0.3),
          do: %{"address" => target, "status" => "reachable"}
        ),
      "complete" => Keyword.fetch!(opts, :complete),
      "resources" => resources
    }
  end

  defp switch(target, serial) do
    %{
      "kind" => "switch",
      "target" => target,
      "identifiers" => %{"serial_number" => serial},
      "attributes" => %{"model" => "S5248F"},
      "interfaces" => []
    }
  end
end
