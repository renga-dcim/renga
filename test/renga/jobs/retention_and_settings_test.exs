defmodule Renga.Jobs.RetentionAndSettingsTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Jobs
  alias Renga.Jobs.JobEvent

  @collect "inventory.collect@1"

  setup do
    %{organization: organization} = context = job_organization_fixture()
    Map.put(context, :agent, agent_fixture(organization))
  end

  defp finished_job(%{scope: scope, agent: agent}, days_ago) do
    {:ok, job} = Jobs.create_job(scope, agent.id, @collect, %{})
    {:ok, job} = Jobs.cancel_job(scope, job.id)

    finished_at = DateTime.add(Renga.Time.utc_now_ms(), -days_ago * 86_400)
    job |> Ecto.Changeset.change(finished_at: finished_at) |> Repo.update!()
  end

  describe "purge_history/1" do
    test "removes finished jobs and their events past 90 days", context do
      old = finished_job(context, 91)
      recent = finished_job(context, 89)

      assert Jobs.purge_history() == 1
      # The purge's longer timeout ends with it (RFD 21).
      assert Repo.query!("SHOW statement_timeout").rows == [["1min"]]

      refute Repo.reload(old)
      assert Repo.reload(recent)
      refute Repo.exists?(from event in JobEvent, where: event.job_id == ^old.id)
    end

    test "follows each organization's retention", context do
      {:ok, _settings} = Jobs.update_settings(context.scope, %{retention_days: 7})
      job = finished_job(context, 8)

      assert Jobs.purge_history() == 1
      refute Repo.reload(job)
    end

    test "never purges open or uncertain jobs", %{scope: scope, agent: agent} do
      {:ok, open} = Jobs.create_job(scope, agent.id, @collect, %{})

      open
      |> Ecto.Changeset.change(inserted_at: DateTime.add(Renga.Time.utc_now_ms(), -200 * 86_400))
      |> Repo.update!()

      assert Jobs.purge_history() == 0
      assert Repo.reload(open)
    end
  end

  describe "settings" do
    test "default to every observe capability and 90 days", %{organization: organization} do
      assert %{allowed_capabilities: [@collect], retention_days: 90} =
               Jobs.get_settings(organization)
    end

    test "owners change them", %{scope: scope, organization: organization} do
      assert {:ok, %{allowed_capabilities: [], retention_days: 30}} =
               Jobs.update_settings(scope, %{allowed_capabilities: [], retention_days: 30})

      assert %{allowed_capabilities: [], retention_days: 30} =
               Jobs.get_settings(Repo.reload!(organization))

      # Omitted fields keep their value.
      assert {:ok, %{allowed_capabilities: [], retention_days: 14}} =
               Jobs.update_settings(scope, %{retention_days: 14})
    end

    test "keep other organization settings", %{scope: scope, organization: organization} do
      organization
      |> Ecto.Changeset.change(settings: %{"other" => true})
      |> Repo.update!()

      {:ok, _settings} = Jobs.update_settings(scope, %{retention_days: 30})
      assert Repo.reload!(organization).settings["other"] == true
    end

    test "are validated", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Jobs.update_settings(scope, %{
                 allowed_capabilities: ["shell.exec@1"],
                 retention_days: 0
               })

      assert %{allowed_capabilities: [_], retention_days: [_]} = errors_on(changeset)
    end

    test "only owners change them", %{organization: organization} do
      assert {:error, :forbidden} =
               Jobs.update_settings(member_scope(organization, "admin"), %{retention_days: 30})
    end
  end

  test "the worker purges on its own interval" do
    parent = self()

    start_supervised!(
      {Renga.Jobs.Sweeper,
       name: nil,
       interval: :timer.hours(1),
       purge_interval: 10,
       sweep: fn -> :ok end,
       purge: fn -> send(parent, :purged) end}
    )

    assert_receive :purged
  end
end
