defmodule RengaWeb.Api.V1.CollectorReportIsolationTest do
  @moduledoc """
  Stage 1 reconciles a whole report in one fenced transaction. Unexpected
  member failures cannot publish partial effects or withdraw unseen resources.
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
  alias Renga.Inventory.ReconciliationWork
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
    test "an unexpected #{table} failure rolls back the report until authorized retry", %{
      scope: scope,
      token: token
    } do
      Repo.query!("""
      CREATE TRIGGER fail_boom BEFORE INSERT ON #{unquote(table)}
      FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_boom()
      """)

      fail_report(scope, token)
    end
  end

  defp fail_report(scope, token) do
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

    report_id = report["observation"]["id"]

    assert [%{status: "failed", errors: %{"processing" => "projection_failed"}}] =
             Inventory.list_observation_reconciliations(scope, report_id)

    assert Inventory.list_derived_observations(scope, report_id) == []

    assert %{work: %{status: "quarantined"} = work, receipt: receipt} =
             ReconciliationWork.accepted(scope, Inventory.get_observation!(scope, report_id))

    # Nothing the failed resource wrote survives, and its unknown contents stop
    # the complete report from withdrawing the switch it did not mention.
    assert Repo.aggregate(
             from(i in "resource_identifiers", where: like(i.value, "SER-BOOM%")),
             :count
           ) == 0

    [stream] = Collectors.list_streams(scope)
    members = Collectors.list_target_resources(scope, stream.id)
    assert length(members) == 1
    assert Enum.all?(members, &CollectorTargetResource.present?/1)

    Repo.query!("SELECT set_config('renga.boom', 'off', false)")
    assert {:ok, resources, true} = Inventory.reconcile_observation(scope, report_id)
    assert length(resources) == 3
    assert ReconciliationWork.get(scope, work.id).status == "succeeded"
    assert ReconciliationWork.receipt(scope, report_id) == receipt

    assert [%{status: "failed"}, %{status: "succeeded"}] =
             Inventory.list_observation_reconciliations(scope, report_id)
  end

  defp post!(token, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-renga-installation-id", "67e55044-10b1-426f-9247-bb680e5fe0c8")
    |> post(~p"/api/v1/observations", payload)
    |> settle_observation()
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
