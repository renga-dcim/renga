defmodule Renga.Release.CLITest do
  # Synchronous: capturing :stderr captures the whole node's standard error,
  # and while async tests run, test files still compiling print warnings there.
  use Renga.DataCase, async: false

  import ExUnit.CaptureIO

  alias Renga.Accounts
  alias Renga.DeploymentAudit.Event
  alias Renga.Inventory
  alias Renga.Operators
  alias Renga.Release.CLI
  alias Renga.Transfers.Archive
  alias Renga.Transfers.Export

  defp run(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, CLI.run(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  test "organization lifecycle commands share retry-safe state and operator audit" do
    organization = Renga.InventoryFixtures.organization_fixture()

    for action <- ~w(suspend schedule-deletion schedule-deletion cancel-deletion resume) do
      {0, output, ""} =
        run(~w(organizations #{action} --organization #{organization.slug} --actor alice))

      assert output =~ organization.slug
    end

    assert Accounts.get_organization!(organization.id).status == "active"
    events = Repo.all(from e in Event, where: e.organization_id == ^organization.id)
    assert length(events) == 5
    assert Enum.all?(events, &(&1.actor == "operator: alice" and &1.outcome == "succeeded"))
    assert Enum.all?(events, &is_binary(&1.invocation_id))
  end

  test "creates a token, prints it once, and audits the actor" do
    {0, stdout, ""} =
      run(~w(operator-tokens create --actor alice --name ci --scopes organizations:read,usage:read
             --source 10.0.0.0/8 --expires-at 2099-01-01T00:00:00Z))

    [plaintext] = Regex.run(~r/renga_operator_\S+/, stdout)
    assert {:ok, token} = Operators.authenticate(plaintext, {10, 1, 2, 3})
    assert token.name == "ci"
    assert token.scopes == ["organizations:read", "usage:read"]
    assert token.expires_at == ~U[2099-01-01 00:00:00.000000Z]

    assert [%{actor: "operator: alice", outcome: "succeeded", invocation_id: invocation}] =
             Repo.all(Event)

    assert {:ok, _uuid} = Ecto.UUID.cast(invocation)
  end

  test "accepts repeated --scope as well as --scopes" do
    {0, _stdout, ""} =
      run(~w(operator-tokens create --actor alice --name ci --scope usage:read
             --scopes policy:read,policy:write))

    assert Operators.get_token("ci").scopes == ~w(usage:read policy:read policy:write)
  end

  test "changes need an actor" do
    {1, "", stderr} = run(~w(operator-tokens create --name ci --scopes usage:read))
    assert stderr =~ "--actor NAME is required"

    {1, "", stderr} = run(["operator-tokens", "create", "--actor", " ", "--name", "ci"])
    assert stderr =~ "--actor NAME is required"

    {1, "", stderr} = run(~w(operator-tokens revoke ci))
    assert stderr =~ "--actor NAME is required"

    refute Operators.get_token("ci")
    assert Repo.all(Event) == []
  end

  test "lists tokens without their secrets" do
    {0, created, ""} = run(~w(operator-tokens create --actor alice --name ci --scopes usage:read))
    {0, stdout, ""} = run(~w(operator-tokens list))

    assert stdout =~ "ci\tactive\tusage:read\tany source"
    [plaintext] = Regex.run(~r/renga_operator_\S+/, created)
    refute stdout =~ plaintext
  end

  test "revokes by name or ID, and audits a missing target" do
    {0, _stdout, ""} = run(~w(operator-tokens create --actor alice --name ci --scopes usage:read))
    token = Operators.get_token("ci")

    {0, stdout, ""} = run(~w(operator-tokens revoke ci --actor alice))
    assert stdout =~ "Revoked operator token ci"
    assert Operators.get_token(token.id).revoked_at

    {0, _stdout, ""} = run(["operator-tokens", "revoke", token.id, "--actor", "alice"])
    {1, "", stderr} = run(~w(operator-tokens revoke missing --actor alice))
    assert stderr =~ "no operator token"

    assert %{outcome: "rejected", reason: "not_found", target_id: nil} =
             Repo.one(from event in Event, where: event.outcome == "rejected")
  end

  test "reports invalid input and unknown commands, auditing refused changes" do
    {1, "", stderr} =
      run(~w(operator-tokens create --actor alice --name ci --scopes inventory:read))

    assert stderr =~ "scopes has an invalid entry"

    {1, "", stderr} =
      run(
        ~w(operator-tokens create --actor alice --name ci --scopes usage:read --expires-at soon)
      )

    assert stderr =~ "--expires-at"

    {1, "", stderr} =
      run([
        "operator-tokens",
        "create",
        "--actor",
        "alice",
        "--name",
        "ci",
        "--scopes",
        "usage:read,"
      ])

    assert stderr =~ "empty entries"

    assert Repo.all(from event in Event, select: {event.outcome, event.reason}) ==
             List.duplicate({"rejected", "invalid"}, 3)

    {1, "", stderr} = run(~w(nope))
    assert stderr =~ "Usage:"
  end

  test "audits malformed changes once an actor is named" do
    for argv <- [
          ~w(operator-tokens create --actor alice --name ci --scopes usage:read unexpected),
          ~w(operator-tokens create --actor alice --name ci --scopes usage:read --bogus x),
          ~w(operator-tokens create --actor alice --scopes usage:read --name),
          ~w(operator-tokens revoke a b --actor alice),
          ~w(operator-tokens revoke --actor alice)
        ] do
      assert {1, "", _stderr} = run(argv)
    end

    assert Repo.all(from event in Event, select: {event.outcome, event.reason}) ==
             List.duplicate({"rejected", "invalid"}, 5)

    refute Operators.get_token("ci")
  end

  test "records actors of any length" do
    actor = String.duplicate("a", 300)

    {0, _stdout, ""} =
      run([
        "operator-tokens",
        "create",
        "--actor",
        actor,
        "--name",
        "ci",
        "--scopes",
        "usage:read"
      ])

    assert Repo.one(from event in Event, select: event.actor) == "operator: " <> actor
  end

  describe "limits" do
    setup do
      %{organization: Renga.InventoryFixtures.organization_fixture()}
    end

    test "sets, shows, and clears an organization's overrides", %{organization: organization} do
      slug = organization.slug

      {0, stdout, ""} =
        run(~w(limits set --organization #{slug} --actor alice --job-creation-rate 600))

      assert stdout =~ "Set job-creation-rate to 600 for #{slug}."
      assert Renga.Limits.get(organization.id, :job_creation_rate) == 600

      {0, stdout, ""} = run(~w(limits show --organization #{slug}))
      assert stdout =~ "job-creation-rate\t600\tjobs per minute\toverride"

      {0, _stdout, ""} =
        run(~w(limits clear --organization #{slug} --actor alice --limit job-creation-rate))

      {0, stdout, ""} = run(~w(limits show --organization #{slug}))
      assert stdout =~ "job-creation-rate\t10000\tjobs per minute\tdefault"

      assert Repo.all(
               from event in Event,
                 order_by: event.inserted_at,
                 select: {event.operation, event.outcome, event.organization_id, event.changed}
             ) == [
               {"limits.set", "succeeded", organization.id, ["job_creation_rate"]},
               {"limits.clear", "succeeded", organization.id, ["job_creation_rate"]}
             ]
    end

    test "refuses unknown organizations, limits, and values", %{organization: organization} do
      slug = organization.slug

      {1, "", stderr} = run(~w(limits set --organization #{slug} --job-creation-rate 1))
      assert stderr =~ "--actor NAME is required"

      {1, "", stderr} =
        run(~w(limits set --organization missing --actor alice --job-creation-rate 1))

      assert stderr =~ "--organization"

      {1, "", stderr} = run(~w(limits set --organization #{slug} --actor alice))
      assert stderr =~ "name at least one limit"

      for value <- ["-1", "9223372036854775808"] do
        {1, "", stderr} =
          run(~w(limits set --organization #{slug} --actor alice --job-creation-rate #{value}))

        assert stderr =~ "limits must be from 0 to 9223372036854775807"
      end

      {1, "", stderr} =
        run(~w(limits set --organization #{slug} --actor alice --intake-rate 1))

      assert stderr =~ "Usage:"

      {1, "", stderr} =
        run(~w(limits clear --organization #{slug} --actor alice --limit nope))

      assert stderr =~ "unknown limit nope"

      assert Renga.Limits.get(organization.id, :job_creation_rate) == 10_000

      assert Repo.all(from event in Event, order_by: event.inserted_at, select: event.reason) ==
               ~w(not_found invalid invalid invalid invalid invalid)
    end

    test "accepts the largest value a limit can have", %{organization: organization} do
      {0, _stdout, ""} =
        run(
          ~w(limits set --organization #{organization.slug} --actor alice --job-creation-rate 9223372036854775807)
        )

      assert Renga.Limits.get(organization.id, :job_creation_rate) == Renga.Limits.max_value()
    end
  end

  describe "export" do
    @describetag :tmp_dir

    setup do
      %{organization: Renga.InventoryFixtures.organization_fixture()}
    end

    test "writes the organization's archive, readable only by its owner, and audits it", %{
      organization: organization,
      tmp_dir: tmp
    } do
      output = Path.join(tmp, "acme.tar.zst")

      {0, stdout, ""} =
        run(
          ~w(export --organization #{organization.slug} --output #{output} --actor alice --history)
        )

      assert stdout =~ "Exported #{organization.slug}"
      assert File.stat!(output).access == :read_write
      assert Bitwise.band(File.stat!(output).mode, 0o077) == 0
      assert File.stat!(output).links == 1
      assert File.ls!(tmp) == ["acme.tar.zst"]

      {:ok, archive} = Archive.open(output, tmp_dir: tmp)
      assert archive.manifest["organization"]["id"] == organization.id
      assert archive.manifest["parts"] == ["history"]
      Archive.close(archive)

      assert [%{operation: "organization.export", outcome: "succeeded", organization_id: id}] =
               Repo.all(Event)

      assert id == organization.id

      assert [%{metadata: %{"operator" => "operator: alice"}}] =
               Repo.all(
                 from event in Renga.Inventory.ChangeEvent,
                   where: event.organization_id == ^organization.id and event.kind == "exported"
               )
    end

    test "never overwrites a file and needs an actor and an organization", %{
      organization: organization,
      tmp_dir: tmp
    } do
      existing = Path.join(tmp, "existing.tar.zst")
      File.write!(existing, "keep me")

      {1, "", stderr} =
        run(~w(export --organization #{organization.slug} --output #{existing} --actor alice))

      assert stderr =~ "already exists"
      assert File.read!(existing) == "keep me"

      {1, "", stderr} = run(~w(export --organization #{organization.slug} --output #{existing}))
      assert stderr =~ "--actor NAME is required"

      {1, "", _stderr} =
        run(~w(export --organization missing --output #{Path.join(tmp, "x")} --actor alice))

      {1, "", stderr} = run(~w(export --organization #{organization.slug} --actor alice))
      assert stderr =~ "--output FILE is required"

      assert Repo.all(from event in Event, order_by: event.inserted_at, select: event.reason) ==
               ~w(invalid not_found invalid)
    end
  end

  describe "import" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      source = Renga.InventoryFixtures.organization_fixture()

      {:ok, _resource} =
        Inventory.create_resource(Accounts.scope_for(source), %{
          kind: "server",
          name: "moved",
          lifecycle_state: "active"
        })

      archive = Path.join(tmp, "source.tar.zst")
      {:ok, _summary} = Export.write(source, archive)
      Repo.delete!(source)

      target = Renga.InventoryFixtures.organization_fixture()
      owner = Renga.AccountsFixtures.user_fixture()
      Renga.InventoryFixtures.organization_membership_fixture(owner, target, %{role: "owner"})

      %{archive: archive, target: target, owner: owner}
    end

    test "imports an archive into an empty organization and audits it", context do
      %{archive: archive, target: target, owner: owner} = context

      {0, stdout, ""} =
        run(
          ~w(import --organization #{target.slug} --input #{archive} --owner #{owner.email} --actor alice)
        )

      assert stdout =~ "into #{target.slug}"
      assert stdout =~ "#{owner.email} can invite people back"
      refute stdout =~ "multi-factor"
      assert Repo.get_by!(Inventory.Resource, name: "moved").organization_id == target.id

      assert [%{metadata: %{"operator" => "operator: alice"}}] =
               Repo.all(
                 from event in Inventory.ChangeEvent,
                   where: event.organization_id == ^target.id and event.kind == "imported"
               )

      # The organization is no longer empty.
      {1, "", stderr} =
        run(
          ~w(import --organization #{target.slug} --input #{archive} --owner #{owner.email} --actor alice)
        )

      assert stderr =~ "#{target.slug} is not empty"

      assert Repo.all(from event in Event, order_by: event.inserted_at, select: event.outcome) ==
               ~w(succeeded failed)
    end

    test "imports a copy beside the original with --copy", context do
      %{target: target, owner: owner, tmp_dir: tmp} = context
      source = Renga.InventoryFixtures.organization_fixture()

      {:ok, original} =
        Inventory.create_resource(Accounts.scope_for(source), %{kind: "server", name: "kept"})

      archive = Path.join(tmp, "kept.tar.zst")
      {:ok, _summary} = Export.write(source, archive)
      args = ~w(import --organization #{target.slug} --input #{archive} --owner #{owner.email})

      {1, "", stderr} = run(args ++ ~w(--actor alice))
      assert stderr =~ "already exist in this deployment"
      assert stderr =~ "--copy"

      {0, stdout, ""} = run(args ++ ~w(--actor alice --copy))
      assert stdout =~ "into #{target.slug}"

      copy = Repo.get_by!(Inventory.Resource, organization_id: target.id, name: "kept")
      assert copy.id != original.id
      assert Repo.get!(Inventory.Resource, original.id).organization_id == source.id
    end

    test "says when the imported organization requires multi-factor authentication",
         context do
      %{target: target, owner: owner, tmp_dir: tmp} = context
      source = Renga.InventoryFixtures.organization_fixture()

      Repo.insert!(%Renga.SecuritySettings.Setting{
        organization_id: source.id,
        name: "require_mfa",
        value: %{"value" => true},
        changed_by: "owner@example.com"
      })

      archive = Path.join(tmp, "mfa.tar.zst")
      {:ok, _summary} = Export.write(source, archive)
      Repo.delete!(source)

      {0, stdout, ""} =
        run(
          ~w(import --organization #{target.slug} --input #{archive} --owner #{owner.email} --actor alice)
        )

      assert stdout =~ "#{target.slug} requires multi-factor authentication: #{owner.email}"
    end

    test "lists every problem with an invalid archive", context do
      %{target: target, owner: owner, tmp_dir: tmp} = context
      input = Path.join(tmp, "broken.tar.zst")
      File.write!(input, "not an archive")

      {1, "", stderr} =
        run(
          ~w(import --organization #{target.slug} --input #{input} --owner #{owner.email} --actor alice)
        )

      assert stderr =~ "The archive is not valid:"

      {1, "", stderr} =
        run(
          ~w(import --organization #{target.slug} --input #{Path.join(tmp, "nope")} --actor alice)
        )

      assert stderr =~ "is not a file"
    end

    test "names the owner who invites everyone back", context do
      %{archive: archive, target: target} = context

      {1, "", stderr} =
        run(~w(import --organization #{target.slug} --input #{archive} --actor alice))

      assert stderr =~ "--owner EMAIL is required"

      stranger = Renga.AccountsFixtures.user_fixture()

      {1, "", stderr} =
        run(
          ~w(import --organization #{target.slug} --input #{archive} --owner #{stranger.email} --actor alice)
        )

      assert stderr =~ "#{stranger.email} is not an active owner of #{target.slug}"
      refute Repo.get_by(Inventory.Resource, name: "moved")
    end
  end
end
