defmodule Renga.Release.CLITest do
  use Renga.DataCase, async: true

  import ExUnit.CaptureIO

  alias Renga.DeploymentAudit.Event
  alias Renga.Operators
  alias Renga.Release.CLI

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

    {1, "", stderr} = run(~w(operator-tokens revoke a b --actor alice))
    assert stderr =~ "Usage:"

    {1, "", stderr} = run(~w(nope))
    assert stderr =~ "Usage:"
  end
end
