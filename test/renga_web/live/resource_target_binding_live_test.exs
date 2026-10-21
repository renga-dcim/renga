defmodule RengaWeb.ResourceTargetBindingLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.JobsFixtures

  alias Renga.Jobs.TargetBindings

  setup %{conn: conn} do
    %{organization: organization, scope: scope} = job_organization_fixture()
    agent = agent_fixture(organization)
    resource = reported_resource_fixture(organization, agent)

    %{
      conn: sign_in(conn, scope.user, organization),
      organization: organization,
      scope: scope,
      agent: agent,
      resource: resource
    }
  end

  defp sign_in(conn, user, organization) do
    conn
    |> log_in_user(user)
    |> put_session(:current_organization_id, organization.id)
  end

  test "binds the resource after showing the key's fingerprint, then unbinds it", context do
    %{conn: conn, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}/sources")

    assert has_element?(view, "#target-binding-none")
    assert has_element?(view, "#bind-target-#{agent.id}", key.fingerprint)

    render_click(view, "bind_target", %{agent_id: agent.id, fingerprint: key.fingerprint})

    assert has_element?(view, "#target-binding-current", agent.name)
    refute has_element?(view, "#target-candidate-#{agent.id}")
    binding = TargetBindings.current(context.scope, resource.id)

    render_click(view, "revoke_target", %{id: binding.id})

    assert has_element?(view, "#target-binding-none")
    assert TargetBindings.current(context.scope, resource.id) == nil
  end

  test "refuses a key that changed after the page loaded", context do
    %{conn: conn, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)
    {:ok, view, _html} = live(conn, ~p"/inventory/#{resource}/sources")
    {_replacement, _private} = approved_key_fixture(organization, agent)

    html = render_click(view, "bind_target", %{agent_id: agent.id, fingerprint: key.fingerprint})

    assert html =~ "key changed"
    assert has_element?(view, "#target-binding-none")
  end

  test "members see the binding without changing it", context do
    %{conn: conn, organization: organization, agent: agent, resource: resource} = context
    {key, _private} = approved_key_fixture(organization, agent)
    {:ok, _binding} = TargetBindings.bind(context.scope, resource.id, agent.id, key.fingerprint)
    member = member_scope(organization, "member")

    {:ok, view, _html} =
      conn
      |> sign_in(member.user, organization)
      |> live(~p"/inventory/#{resource}/sources")

    assert has_element?(view, "#target-binding-current", agent.name)
    refute has_element?(view, "#revoke-target-binding-button")
    refute has_element?(view, "#target-binding-candidates")
  end
end
