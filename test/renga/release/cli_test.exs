defmodule Renga.Release.CLITest do
  use Renga.DataCase, async: true

  import ExUnit.CaptureIO

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

  test "creates a token and prints it once" do
    {0, stdout, ""} =
      run(~w(operator-tokens create --name ci --scope organizations:read --scope usage:read
             --source 10.0.0.0/8 --expires-at 2099-01-01T00:00:00Z))

    [plaintext] = Regex.run(~r/renga_operator_\S+/, stdout)
    assert {:ok, token} = Operators.authenticate(plaintext, {10, 1, 2, 3})
    assert token.name == "ci"
    assert token.scopes == ["organizations:read", "usage:read"]
    assert token.expires_at == ~U[2099-01-01 00:00:00.000000Z]
  end

  test "lists tokens without their secrets" do
    {0, created, ""} = run(~w(operator-tokens create --name ci --scope usage:read))
    {0, stdout, ""} = run(~w(operator-tokens list))

    assert stdout =~ "ci\tactive\tusage:read\tany source"
    [plaintext] = Regex.run(~r/renga_operator_\S+/, created)
    refute stdout =~ plaintext
  end

  test "revokes by name or ID" do
    {0, _stdout, ""} = run(~w(operator-tokens create --name ci --scope usage:read))
    token = Operators.get_token("ci")

    {0, stdout, ""} = run(["operator-tokens", "revoke", "ci"])
    assert stdout =~ "Revoked operator token ci"
    assert Operators.get_token(token.id).revoked_at

    {0, _stdout, ""} = run(["operator-tokens", "revoke", token.id])
    {1, "", stderr} = run(["operator-tokens", "revoke", "missing"])
    assert stderr =~ "no operator token"
  end

  test "reports invalid input and unknown commands" do
    {1, "", stderr} = run(~w(operator-tokens create --name ci --scope inventory:read))
    assert stderr =~ "scopes has an invalid entry"

    {1, "", stderr} =
      run(~w(operator-tokens create --name ci --scope usage:read --expires-at soon))

    assert stderr =~ "--expires-at"

    {1, "", stderr} = run(~w(nope))
    assert stderr =~ "Usage:"
  end
end
