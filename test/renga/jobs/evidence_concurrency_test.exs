defmodule Renga.Jobs.EvidenceConcurrencyTest do
  # Reservations and expiry must survive actual commits on independent connections.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Renga.JobsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Jobs.Evidence
  alias Renga.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    context = job_organization_fixture()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from o in Accounts.Organization, where: o.id == ^context.organization.id)
      Repo.delete!(context.scope.user)
      Sandbox.checkin(Repo)
    end)

    context
  end

  test "independent installations cannot double-grant the last protected slot", c do
    agents =
      for _ <- 1..2 do
        agent = agent_fixture(c.organization)
        {:ok, _} = Jobs.create_job(c.scope, agent.id, "inventory.collect@1", %{})
        agent
      end

    # This committed fixture must not leave immutable deployment-audit records
    # outside the organization cascade. Audited limit writes are tested separately.
    Repo.insert!(%Renga.Limits.OrganizationLimit{
      organization_id: c.organization.id,
      name: "job_evidence_items",
      value: 1
    })

    results =
      agents
      |> Task.async_stream(
        fn agent ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Jobs.lease_jobs(c.system_scope, agent, ["inventory.collect@1"], 1)
          after
            Sandbox.checkin(Repo)
          end
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, [{_, _}]}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :evidence_capacity})) == 1
    assert Evidence.usage(c.organization.id, :items) == 1

    assert Repo.aggregate(
             from(j in Jobs.Job,
               where: j.organization_id == ^c.organization.id and j.state == "queued"
             ),
             :count
           ) == 1
  end

  test "a submission waiting across the lease cutoff cannot admit evidence", c do
    agent = agent_fixture(c.organization)
    {:ok, _job} = Jobs.create_job(c.scope, agent.id, "inventory.collect@1", %{})
    {:ok, [{job, token}]} = Jobs.lease_jobs(c.system_scope, agent, ["inventory.collect@1"], 1)
    {:ok, {key, _}} = Inventory.create_intake_api_key(c.scope, %{name: "Evidence"})

    body =
      Jason.encode!(%{
        observation_id: Ecto.UUID.generate(),
        observed_at: "2026-07-31T12:00:00Z",
        resources: [
          %{
            kind: "server",
            identifiers: %{hostname: "late-host"},
            attributes: %{hostname: "late-host"}
          }
        ]
      })

    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    parent = self()

    {:ok, waiting} =
      Repo.transaction(fn ->
        Repo.update!(
          Ecto.Changeset.change(job, lease_expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1))
        )

        waiting =
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)
            send(parent, {:backend, Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()})

            try do
              Evidence.submit(
                c.system_scope,
                key,
                agent.installation_id,
                job.id,
                job.attempts,
                token,
                digest,
                body
              )
            after
              Sandbox.checkin(Repo)
            end
          end)

        assert_receive {:backend, backend}
        await_lock(backend, System.monotonic_time(:millisecond) + 2_000)
        waiting
      end)

    assert Task.await(waiting) == {:error, :lease_not_held}
    assert %{lapsed: 1} = Jobs.sweep()
    assert Repo.reload!(job).state == "queued"
    assert Evidence.usage(c.organization.id, :items) == 0
    assert Evidence.usage(c.organization.id, :bytes) == 0
    assert Inventory.list_observations(c.system_scope) == []
  end

  test "ordinary intake and protected submission lock organization before installation", c do
    {:ok, {key, _}} = Inventory.create_intake_api_key(c.scope, %{name: "Shared installation"})
    installation = Ecto.UUID.generate()

    {:ok, {agent, _}} =
      Inventory.record_intake_agent_check_in(c.system_scope, key, installation, %{
        capabilities: ["inventory.collect@1"]
      })

    {:ok, _} = Jobs.create_job(c.scope, agent.id, "inventory.collect@1", %{})
    {:ok, [{job, token}]} = Jobs.lease_jobs(c.system_scope, agent, ["inventory.collect@1"], 1)

    payload = %{
      "observation_id" => Ecto.UUID.generate(),
      "observed_at" => "2026-11-10T00:00:00Z",
      "resources" => [
        %{
          "kind" => "server",
          "identifiers" => %{"hostname" => "racing-host"},
          "attributes" => %{}
        }
      ]
    }

    {:ok, attrs} =
      Inventory.AgentPayload.validate_observation(payload, %Inventory.Source{kind: "host_agent"})

    protected = Jason.encode!(%{payload | "observation_id" => Ecto.UUID.generate()})
    digest = :crypto.hash(:sha256, protected) |> Base.encode16(case: :lower)
    parent = self()
    handler = "protected-lock-order-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:renga, :repo, :query],
      fn _, _, metadata, {parent, handler} ->
        if Process.get(handler) &&
             metadata.query == "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))" do
          Process.delete(handler)
          send(parent, {:ordinary_fenced, self()})

          receive do
            {:continue, ^handler} -> :ok
          after
            5_000 -> raise "ordinary intake barrier was not released"
          end
        end
      end,
      {parent, handler}
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    ordinary =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        Process.put(handler, true)

        try do
          Inventory.ingest_intake_observation(c.system_scope, key, installation, %{}, attrs)
        after
          Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:ordinary_fenced, caller}, 1_000

    submission =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        send(
          parent,
          {:protected_backend, Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()}
        )

        try do
          Evidence.submit(
            c.system_scope,
            key,
            installation,
            job.id,
            job.attempts,
            token,
            digest,
            protected
          )
        after
          Sandbox.checkin(Repo)
        end
      end)

    assert_receive {:protected_backend, backend}, 1_000
    await_lock(backend, System.monotonic_time(:millisecond) + 2_000)
    send(caller, {:continue, handler})
    assert {:ok, {_, _, _, :created}} = Task.await(ordinary)
    assert {:ok, {_, :created}} = Task.await(submission)
    assert length(Inventory.list_observations(c.system_scope)) == 2
    assert Evidence.usage(c.organization.id, :items) == 1
  end

  defp await_lock(backend, deadline) do
    if Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows ==
         [["Lock"]] do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "submission did not wait for the expiry lock"

      Process.sleep(5)
      await_lock(backend, deadline)
    end
  end
end
