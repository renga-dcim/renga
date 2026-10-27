defmodule RengaWeb.AgentChannelTest do
  use RengaWeb.ChannelCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias RengaWeb.AgentSocket

  @collect "inventory.collect@1"

  setup do
    %{organization: organization, scope: scope} = context = job_organization_fixture()
    installation_id = Ecto.UUID.generate()

    {:ok, {key, token}} = Inventory.create_intake_api_key(scope, %{name: "Fleet"})
    {:ok, authenticated} = Inventory.authenticate_intake_api_key(token)

    {:ok, {agent, _lease}} =
      Inventory.record_intake_agent_check_in(
        Accounts.scope_for(organization),
        authenticated,
        installation_id,
        %{capabilities: [@collect]}
      )

    Map.merge(context, %{agent: agent, key: key, token: token, installation_id: installation_id})
  end

  defp connect_agent(token, installation_id) do
    connect(AgentSocket, %{},
      connect_info: %{
        auth_token: token,
        x_headers: [{"x-renga-installation-id", installation_id}]
      }
    )
  end

  defp join_own(context) do
    {:ok, socket} = connect_agent(context.token, context.installation_id)
    subscribe_and_join(socket, "installation:#{context.installation_id}", %{})
  end

  describe "connect" do
    test "accepts the intake key and installation the HTTPS API accepts", context do
      assert {:ok, socket} = connect_agent(context.token, context.installation_id)
      assert socket.assigns.current_installation_id == context.installation_id
      assert socket.assigns.current_scope.organization_id == context.organization.id
    end

    test "refuses a missing or unknown key", context do
      assert :error = connect_agent(nil, context.installation_id)
      assert :error = connect_agent("renga_intake_unknown", context.installation_id)
    end

    test "refuses a missing or malformed installation ID", context do
      assert :error = connect(AgentSocket, %{}, connect_info: %{auth_token: context.token})
      assert :error = connect_agent(context.token, "not-a-uuid")
    end

    test "refuses a revoked key", context do
      {:ok, _key} = Inventory.revoke_intake_api_key(context.scope, context.key.id)
      assert :error = connect_agent(context.token, context.installation_id)
    end
  end

  describe "join" do
    test "replies whether jobs are already waiting", context do
      assert {:ok, %{jobs_waiting: false}, _socket} = join_own(context)

      {:ok, _job} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})
      assert {:ok, %{jobs_waiting: true}, _socket} = join_own(context)
    end

    test "only joins the installation the socket authenticated as", context do
      {:ok, socket} = connect_agent(context.token, context.installation_id)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "installation:#{Ecto.UUID.generate()}", %{})
    end

    test "accepts the installation ID in any case", context do
      {:ok, socket} = connect_agent(context.token, context.installation_id)
      topic = "installation:#{String.upcase(context.installation_id)}"

      assert {:ok, _reply, _socket} = subscribe_and_join(socket, topic, %{})
    end

    test "needs an installation that has checked in", context do
      installation_id = Ecto.UUID.generate()
      {:ok, socket} = connect_agent(context.token, installation_id)

      assert {:error, %{reason: "agent_not_registered"}} =
               subscribe_and_join(socket, "installation:#{installation_id}", %{})
    end
  end

  describe "notices" do
    test "pushes jobs_waiting, without the job, when a job is queued", context do
      {:ok, _reply, _socket} = join_own(context)

      {:ok, _job} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})

      assert_push "jobs_waiting", payload
      assert payload == %{}
    end

    test "stays quiet about other agents' jobs", context do
      {:ok, _reply, _socket} = join_own(context)
      other = agent_fixture(context.organization)

      {:ok, _job} = Jobs.create_job(context.scope, other.id, @collect, %{})

      refute_push "jobs_waiting", _payload
    end

    test "closes once the key is revoked", context do
      {:ok, _reply, socket} = join_own(context)
      Process.monitor(socket.channel_pid)

      {:ok, _key} = Inventory.revoke_intake_api_key(context.scope, context.key.id)
      send(socket.channel_pid, :recheck)

      assert_receive {:DOWN, _ref, :process, _pid, :normal}
    end

    test "stays open while the key and agent are current", context do
      {:ok, _reply, socket} = join_own(context)
      send(socket.channel_pid, :recheck)

      {:ok, _job} = Jobs.create_job(context.scope, context.agent.id, @collect, %{})
      assert_push "jobs_waiting", _payload
    end

    test "does not deliver a queued notification after suspension even without invalidation",
         context do
      {:ok, _reply, socket} = join_own(context)
      Process.monitor(socket.channel_pid)

      # Simulate an unavailable invalidation channel: the delivery guard is
      # authoritative even before the fallback timer wakes up.
      context.organization |> Ecto.Changeset.change(status: "disabled") |> Renga.Repo.update!()
      send(socket.channel_pid, {:jobs_waiting, context.agent.id})

      assert_receive {:DOWN, _ref, :process, _pid, :normal}
      refute_push "jobs_waiting", _payload
    end
  end
end
