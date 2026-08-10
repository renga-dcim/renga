defmodule RengaWeb.EnrollmentSettingsLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Enrollment

  setup %{conn: conn} do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "admin"})
    scope = Accounts.scope_for_user(user, organization.id)

    conn = conn |> log_in_user(user) |> put_session(:current_organization_id, organization.id)
    %{conn: conn, scope: scope, membership: membership, organization: organization}
  end

  test "admin creates, lists, receives config, and disables a profile", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/inventory/enrollment")
    assert has_element?(view, "#enrollment-settings")
    assert has_element?(view, "#enrollment-profile-form")

    view |> form("#enrollment-profile-form", profile: valid_attrs()) |> render_submit()
    [profile] = Enrollment.list_profiles(scope)

    assert has_element?(view, "#enrollment-profile-#{profile.id}", "Production")
    assert has_element?(view, "#agent-config-snippet", "auth_mode = \"enrolled\"")
    assert has_element?(view, "#agent-config-snippet", "profile = \"production\"")
    refute has_element?(view, "#agent-config-snippet", "token =")

    view |> element("#disable-enrollment-profile-#{profile.id}") |> render_click()
    refute Enrollment.get_profile!(scope, profile.id).enabled
    refute has_element?(view, "#disable-enrollment-profile-#{profile.id}")
  end

  test "viewer can list but forged create and disable events are rejected", %{scope: admin_scope} do
    {:ok, profile} = Enrollment.create_oidc_profile(admin_scope, valid_attrs())
    user = user_fixture()
    organization = admin_scope.organization
    organization_membership_fixture(user, organization, %{role: "viewer"})

    conn =
      build_conn() |> log_in_user(user) |> put_session(:current_organization_id, organization.id)

    {:ok, view, _html} = live(conn, ~p"/inventory/enrollment")
    assert has_element?(view, "#enrollment-profile-#{profile.id}")
    refute has_element?(view, "#enrollment-profile-form")
    refute has_element?(view, "#disable-enrollment-profile-#{profile.id}")

    render_hook(view, "create", %{"profile" => valid_attrs(%{"selector" => "forged"})})
    render_hook(view, "disable", %{"id" => profile.id})

    assert Enrollment.get_profile!(admin_scope, profile.id).enabled
    assert length(Enrollment.list_profiles(admin_scope)) == 1
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Production",
        "selector" => "production",
        "issuer" => "https://issuer.example",
        "audience" => "renga-agent",
        "jwks_url" => "https://issuer.example/jwks",
        "algorithm" => "EdDSA",
        "subject_claim" => "sub",
        "subject_cardinality" => "singleton",
        "binding_mode" => "challenge_bound",
        "required_claim_path" => "role",
        "required_claim_value" => "installer"
      },
      overrides
    )
  end
end
