defmodule Renga.SecuritySettingsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Accounts.SessionMFA
  alias Renga.Inventory.ChangeEvent
  alias Renga.SecuritySettings
  alias RengaWeb.ChangeDescription

  defp member_scope(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Accounts.scope_for_user(user, organization.id)
  end

  setup do
    organization = organization_fixture()
    %{organization: organization, owner: member_scope(organization, "owner")}
  end

  test "settings start at their defaults", %{organization: organization, owner: owner} do
    refute SecuritySettings.require_mfa?(organization.id)

    assert [%{name: :require_mfa, value: false, changed_by: nil, changed_at: nil}] =
             SecuritySettings.list(owner)
  end

  test "an owner changes a setting, recorded in Activity with the reason", %{
    organization: organization,
    owner: owner
  } do
    assert {:ok, true} =
             SecuritySettings.put(owner, :require_mfa, true, "  Audit finding 12  ")

    assert SecuritySettings.require_mfa?(organization.id)

    assert [%{value: true, changed_by: email, changed_at: %DateTime{}}] =
             SecuritySettings.list(owner)

    assert email == owner.user.email

    assert [event] = Repo.all(where(ChangeEvent, kind: "security_setting_changed"))

    assert %{
             field: "require_mfa",
             old_value: %{"value" => false},
             new_value: %{"value" => true},
             metadata: %{"reason" => "Audit finding 12"}
           } = event

    assert event.actor_user_id == owner.user.id
    assert event.organization_id == organization.id

    assert ChangeDescription.describe(event) ==
             "Required multi-factor authentication for members · Audit finding 12"
  end

  test "setting the value already in place records nothing", %{owner: owner} do
    assert {:ok, false} = SecuritySettings.put(owner, :require_mfa, false)
    {:ok, true} = SecuritySettings.put(owner, :require_mfa, true, "Policy requirement")

    owner = %{owner | user: %{owner.user | session_mfa: SessionMFA.for_method(:passkey)}}
    {:ok, true} = SecuritySettings.put(owner, :require_mfa, true)

    assert Repo.aggregate(where(ChangeEvent, kind: "security_setting_changed"), :count) == 1
  end

  test "a changed value needs a non-blank reason", %{organization: organization, owner: owner} do
    for reason <- [nil, "", " \n\t "] do
      assert {:error, :reason_required} =
               SecuritySettings.put(owner, :require_mfa, true, reason)
    end

    refute SecuritySettings.require_mfa?(organization.id)
    assert Repo.aggregate(where(ChangeEvent, kind: "security_setting_changed"), :count) == 0
  end

  test "needs organization.manage", %{organization: organization} do
    for role <- ~w(admin member viewer) do
      scope = member_scope(organization, role)
      assert {:error, :forbidden} = SecuritySettings.put(scope, :require_mfa, true)
    end

    assert {:error, :forbidden} =
             SecuritySettings.put(Accounts.Scope.for_user(user_fixture()), :require_mfa, true)

    refute SecuritySettings.require_mfa?(organization.id)
  end

  test "refuses a value of the wrong type", %{owner: owner} do
    assert {:error, :invalid} = SecuritySettings.put(owner, :require_mfa, "yes")
  end

  test "each organization has its own settings", %{organization: organization, owner: owner} do
    other = organization_fixture()
    {:ok, true} = SecuritySettings.put(owner, :require_mfa, true, "Organization policy")

    assert SecuritySettings.require_mfa?(organization.id)
    refute SecuritySettings.require_mfa?(other.id)
  end
end
