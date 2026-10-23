defmodule RengaWeb.SecurityLiveTest do
  use RengaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.SessionMFA
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.SecuritySettings

  defp member_conn(conn, role, opts \\ []) do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user, opts)
      |> put_session(:current_organization_id, organization.id)

    {conn, user, organization}
  end

  test "lists each setting with its value and that it was never changed", %{conn: conn} do
    {conn, _user, _organization} = member_conn(conn, "owner")

    {:ok, view, _html} = live(conn, ~p"/settings/security")

    assert has_element?(view, "#setting-require_mfa", "Require multi-factor authentication")
    assert has_element?(view, "#setting-require_mfa-value", "Off")
    assert has_element?(view, "#setting-require_mfa-changed", "Default, never changed")
    assert has_element?(view, "#setting-require_mfa-form")
    assert has_element?(view, "#setting-require_mfa-reason[required]")
  end

  test "an owner turns on the MFA requirement with a reason", %{conn: conn} do
    mfa = SessionMFA.for_method(:passkey)
    {conn, user, organization} = member_conn(conn, "owner", mfa: mfa)
    totp_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/settings/security")
    refute has_element?(view, "#setting-require_mfa-no-factor")

    view
    |> form("#setting-require_mfa-form",
      setting: %{value: "true", reason: "SOC 2 control AC-3"}
    )
    |> render_submit()

    assert SecuritySettings.require_mfa?(organization.id)
    assert has_element?(view, "#setting-require_mfa-value", "On")
    assert has_element?(view, "#setting-require_mfa-changed", "Last changed by #{user.email}")

    assert [%{metadata: %{"reason" => "SOC 2 control AC-3"}}] =
             Repo.all(where(ChangeEvent, kind: "security_setting_changed"))

    {:ok, _view, html} = live(conn, ~p"/activity")
    assert html =~ "Required multi-factor authentication for members · SOC 2 control AC-3"
  end

  test "a blank reason leaves the setting unchanged", %{conn: conn} do
    {conn, _user, organization} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/security")

    html =
      view
      |> form("#setting-require_mfa-form", setting: %{value: "true", reason: "  "})
      |> render_submit()

    assert html =~ "Enter a reason for this security change."
    refute SecuritySettings.require_mfa?(organization.id)
    assert Repo.aggregate(where(ChangeEvent, kind: "security_setting_changed"), :count) == 0
  end

  test "an owner whose session has no second factor is asked for one after turning it on", %{
    conn: conn
  } do
    {conn, user, _organization} = member_conn(conn, "owner")
    totp_fixture(user)

    {:ok, view, _html} = live(conn, ~p"/settings/security")

    assert {:error, {:redirect, %{to: "/organizations/confirm-mfa"}}} =
             view
             |> form("#setting-require_mfa-form",
               setting: %{value: "true", reason: "Organization policy"}
             )
             |> render_submit()
  end

  test "warns an owner with no factor of their own", %{conn: conn} do
    {conn, _user, _organization} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/security")

    assert has_element?(view, "#setting-require_mfa-no-factor")
  end

  test "other members see the settings but cannot change them", %{conn: conn} do
    {conn, _user, _organization} = member_conn(conn, "admin")

    {:ok, view, _html} = live(conn, ~p"/settings/security")

    assert has_element?(view, "#setting-require_mfa-value", "Off")
    refute has_element?(view, "#setting-require_mfa-form")
  end

  test "a change refused in the database leaves the setting as it was", %{conn: conn} do
    {conn, user, organization} = member_conn(conn, "owner")
    {:ok, view, _html} = live(conn, ~p"/settings/security")

    # Demoted after the page loaded.
    Repo.update_all(
      from(m in Renga.Accounts.OrganizationMembership,
        where: m.user_id == ^user.id and m.organization_id == ^organization.id
      ),
      set: [role: "member"]
    )

    html =
      view
      |> form("#setting-require_mfa-form",
        setting: %{value: "true", reason: "Organization policy"}
      )
      |> render_submit()

    assert html =~ "needs organization.manage"
    refute SecuritySettings.require_mfa?(organization.id)
  end
end
