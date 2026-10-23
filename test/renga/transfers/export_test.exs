defmodule Renga.Transfers.ExportTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Accounts
  alias Renga.Inventory
  alias Renga.Jobs
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Export

  @moduletag :tmp_dir
  @collect "inventory.collect@1"

  setup do
    %{organization: organization, scope: owner, system_scope: system_scope} =
      job_organization_fixture()

    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent)
    %{binding: binding, key: key} = target_binding_fixture(organization, agent)

    # An observation no current evidence or claim points at.
    {:ok, loose} =
      Inventory.create_observation(system_scope, agent.source_id, %{
        observation_id: "loose",
        observed_at: Renga.Time.utc_now_ms(),
        payload: %{"hostname" => "loose"}
      })

    {:ok, {intake_key, intake_token}} =
      Inventory.create_intake_api_key(owner, %{name: "datacenter-a"})

    {:ok, job} = Jobs.create_job(owner, agent.id, @collect, %{})
    {:ok, [{_job, lease_token}]} = Jobs.lease_jobs(system_scope, agent, [@collect], 1)

    other = Renga.InventoryFixtures.organization_fixture()

    {:ok, other_resource} =
      Inventory.create_resource(Accounts.scope_for(other), %{
        kind: "server",
        name: "other-organization",
        lifecycle_state: "active"
      })

    %{
      organization: organization,
      owner: owner,
      agent: agent,
      resource: resource,
      binding: binding,
      key: key,
      loose: loose,
      intake_key: intake_key,
      intake_token: intake_token,
      job: job,
      lease_token: lease_token,
      other_resource: other_resource
    }
  end

  defp export(context, opts \\ []) do
    path = Path.join(context.tmp_dir, "export-#{System.unique_integer([:positive])}.tar.zst")
    assert {:ok, summary} = Export.write(context.organization, path, opts)
    assert {:ok, archive} = Archive.open(path, tmp_dir: context.tmp_dir)
    on_exit(fn -> Archive.close(archive) end)
    {archive, summary}
  end

  defp records(archive, type), do: archive |> Archive.records(type) |> Enum.to_list()
  defp ids(archive, type), do: archive |> records(type) |> Enum.map(& &1["id"])

  test "exports the organization's current state as one snapshot", context do
    {archive, summary} = export(context)
    %{id: id, slug: slug, name: name} = context.organization

    assert %{
             "organization" => %{"id" => ^id, "slug" => ^slug, "name" => ^name},
             "parts" => []
           } = archive.manifest

    assert archive.manifest["snapshot_at"] == DateTime.to_iso8601(summary.snapshot_at)

    assert [%{"name" => ^name, "slug" => ^slug, "settings" => %{}} = record] =
             records(archive, "organization")

    refute Map.has_key?(record, "status")

    resource_ids = ids(archive, "resources")
    assert context.resource.id in resource_ids
    assert context.binding.resource_id in resource_ids
    refute context.other_resource.id in resource_ids

    assert [resource] =
             Enum.filter(records(archive, "resources"), &(&1["id"] == context.resource.id))

    assert resource["name"] == "compute-01"
    assert resource["inserted_at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z\z/
    refute Map.has_key?(resource, "organization_id")

    assert ids(archive, "agents") == [context.agent.id]
    assert ids(archive, "target_bindings") == [context.binding.id]
    assert [%{"public_key" => public_key}] = records(archive, "installation_keys")
    assert Base.decode64!(public_key) == context.key.public_key

    assert [%{"name" => "datacenter-a"} = intake_key] = records(archive, "intake_api_keys")
    assert Map.keys(intake_key) |> Enum.sort() == ~w(id inserted_at name status updated_at)

    # History is left out by default.
    for type <- ~w(change_events resource_revisions jobs job_events) do
      refute type in Archive.record_types(archive)
    end

    assert summary.records ==
             Enum.sum(Enum.map(archive.manifest["files"], fn {_f, e} -> e["records"] end))
  end

  test "exports only the observations current evidence needs, unless asked for all", context do
    {archive, _summary} = export(context)

    needed = ids(archive, "observations")
    claimed = Enum.map(records(archive, "resource_identifier_claims"), & &1["observation_id"])
    assert needed != []
    assert Enum.sort(Enum.uniq(claimed)) == Enum.sort(needed)
    refute context.loose.id in needed

    for reconciliation <- records(archive, "observation_reconciliations"),
        do: assert(reconciliation["observation_id"] in needed)

    {archive, _summary} = export(context, parts: ["raw_observations"])
    assert context.loose.id in ids(archive, "observations")
    assert archive.manifest["parts"] == ["raw_observations"]
  end

  test "names people through principals, with their email", context do
    {archive, _summary} = export(context, parts: ["history"])

    principals = Map.new(records(archive, "principals"), &{&1["id"], &1["email"]})

    for membership <- records(archive, "organization_memberships") do
      assert {:ok, _email} = Map.fetch(principals, membership["user_id"])
    end

    assert principals[context.owner.user.id] == context.owner.user.email

    [key] = records(archive, "installation_keys")
    assert Map.has_key?(principals, key["approved_by_user_id"])

    [job] = records(archive, "jobs")
    assert job["id"] == context.job.id
    assert principals[job["requested_by_user_id"]] == context.owner.user.email
  end

  test "includes history when asked, without job credentials", context do
    {archive, _summary} = export(context, parts: ["history"])

    assert [job] = records(archive, "jobs")
    assert job["state"] == "leased"

    for field <- ~w(lease_token_hash report_token_hash offer_token_hash offer_nonce),
        do: refute(Map.has_key?(job, field))

    assert [_ | _] = records(archive, "job_events")
    assert [_ | _] = records(archive, "change_events")

    assert context.resource.id in Enum.map(
             records(archive, "resource_revisions"),
             & &1["resource_id"]
           )
  end

  test "no credential appears anywhere in the archive", context do
    Accounts.generate_user_session_token(context.owner.user)
    {archive, _summary} = export(context, parts: ["history", "raw_observations"])

    %{rows: rows} =
      Repo.query!(
        """
        SELECT hashed_password::bytea FROM users WHERE hashed_password IS NOT NULL
        UNION ALL SELECT token FROM users_tokens
        UNION ALL SELECT token_hash FROM intake_api_keys
        UNION ALL SELECT lease_token_hash FROM jobs WHERE lease_token_hash IS NOT NULL
        UNION ALL SELECT report_token_hash FROM jobs WHERE report_token_hash IS NOT NULL
        """,
        []
      )

    secrets = [context.intake_token, context.lease_token | List.flatten(rows)]
    assert length(secrets) >= 4

    contents =
      archive.dir
      |> File.ls!()
      |> Enum.map_join(&File.read!(Path.join(archive.dir, &1)))

    for secret <- secrets,
        encoded <- [
          secret,
          Base.encode16(secret, case: :lower),
          Base.encode16(secret),
          Base.encode64(secret),
          Base.url_encode64(secret, padding: false)
        ] do
      refute String.contains?(contents, encoded), "the archive contains a credential"
    end
  end

  test "names the organization in its manifest as the snapshot found it", context do
    # The caller loaded the organization before it was renamed.
    context.organization
    |> Ecto.Changeset.change(
      name: "Renamed",
      slug: "renamed-#{System.unique_integer([:positive])}"
    )
    |> Repo.update!()

    {archive, _summary} = export(context)
    [organization] = records(archive, "organization")

    assert archive.manifest["organization"]["name"] == "Renamed"
    assert archive.manifest["organization"]["slug"] == organization["slug"]
  end

  test "refuses unknown parts", context do
    assert_raise ArgumentError, fn ->
      Export.write(context.organization, Path.join(context.tmp_dir, "x"), parts: ["everything"])
    end
  end
end
