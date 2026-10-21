defmodule Renga.Inventory.InstallationKeysTest do
  use Renga.DataCase, async: true

  import Renga.JobsFixtures

  alias Renga.Findings
  alias Renga.Inventory.CollectorFinding
  alias Renga.Inventory.InstallationKey
  alias Renga.Inventory.InstallationKeys

  setup do
    %{organization: organization} = context = job_organization_fixture()
    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent)
    Map.merge(context, %{agent: agent, resource: resource})
  end

  defp public_key, do: :crypto.strong_rand_bytes(32)

  defp present(agent, public_key) do
    {:ok, key} =
      Repo.transaction(fn ->
        InstallationKeys.present!(
          agent,
          %{algorithm: "ed25519", public_key: public_key},
          Renga.Time.utc_now_ms()
        )
      end)

    key
  end

  defp findings(agent) do
    CollectorFinding
    |> where([finding], finding.agent_id == ^agent.id)
    |> order_by([finding], asc: finding.inserted_at)
    |> Repo.all()
  end

  test "the fingerprint is the unpadded base64 SHA-256 of the raw key" do
    key = <<0::256>>
    digest = :crypto.hash(:sha256, key) |> Base.encode64(padding: false)
    assert InstallationKey.fingerprint(key) == "SHA256:" <> digest
  end

  test "the first key is pending and presenting it again changes nothing", %{agent: agent} do
    raw = public_key()
    key = present(agent, raw)
    assert key.status == "pending"
    assert key.fingerprint == InstallationKey.fingerprint(raw)

    again = present(agent, raw)
    assert again.id == key.id
    assert again.status == "pending"
  end

  test "an owner approves the fingerprint they compared", %{agent: agent, scope: scope} do
    key = present(agent, public_key())

    assert {:ok, approved} = InstallationKeys.approve(scope, key.id, key.fingerprint)
    assert approved.status == "approved"
    assert approved.approved_by_user_id == scope.user.id
    assert InstallationKeys.current(scope, agent.id).status == "approved"
  end

  test "a key replaced after the page loaded is not approved unseen",
       %{agent: agent, scope: scope} do
    key = present(agent, public_key())
    _replacement = present(agent, public_key())

    assert {:error, :key_changed} = InstallationKeys.approve(scope, key.id, key.fingerprint)

    current = InstallationKeys.current(scope, agent.id)
    assert {:error, :key_changed} = InstallationKeys.approve(scope, current.id, key.fingerprint)
  end

  test "members and admins of other organizations cannot approve",
       %{agent: agent, organization: organization} do
    key = present(agent, public_key())

    assert {:error, :forbidden} =
             InstallationKeys.approve(
               member_scope(organization, "member"),
               key.id,
               key.fingerprint
             )

    other = job_organization_fixture()
    assert {:error, :not_found} = InstallationKeys.approve(other.scope, key.id, key.fingerprint)
  end

  test "changing a pending key opens no finding", %{agent: agent, scope: scope} do
    first = present(agent, public_key())
    second = present(agent, public_key())

    assert Repo.reload!(first).status == "replaced"
    assert InstallationKeys.current(scope, agent.id).id == second.id
    assert findings(agent) == []
  end

  test "changing an approved key returns to pending and opens a finding on the reported resource",
       %{agent: agent, scope: scope, resource: resource} do
    approved = present(agent, public_key())
    {:ok, _key} = InstallationKeys.approve(scope, approved.id, approved.fingerprint)

    replacement = present(agent, public_key())
    assert replacement.status == "pending"
    assert Repo.reload!(approved).status == "replaced"

    assert [finding] = findings(agent)
    assert finding.status == "open"
    assert finding.resource_id == resource.id
    assert finding.details["previous_fingerprint"] == approved.fingerprint
    assert finding.details["fingerprint"] == replacement.fingerprint

    assert {[%{domain: "collector", kind: "installation_key_changed", group: "health"}], _total} =
             Findings.list_findings(scope, domain: "collector")

    {:ok, _key} = InstallationKeys.approve(scope, replacement.id, replacement.fingerprint)
    assert [%{status: "resolved"}] = findings(agent)
  end

  test "further changes before approval keep the one finding", %{agent: agent, scope: scope} do
    approved = present(agent, public_key())
    {:ok, _key} = InstallationKeys.approve(scope, approved.id, approved.fingerprint)

    _second = present(agent, public_key())
    third = present(agent, public_key())

    assert [finding] = findings(agent)
    assert finding.status == "open"
    assert finding.details["previous_fingerprint"] == approved.fingerprint
    # The Inbox names the key that now awaits approval, not the one it replaced.
    assert finding.details["fingerprint"] == third.fingerprint

    {:ok, _key} = InstallationKeys.approve(scope, third.id, third.fingerprint)
    assert [%{status: "resolved"}] = findings(agent)
  end
end
