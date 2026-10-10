defmodule RengaWeb.InboxAddressLiveTest do
  @moduledoc """
  Address findings in the Inbox (RFD 4, Phase 5): they join the queue as the
  `address` domain with the shared workflow, link to where they are fixed,
  and an unmanaged address in a strict prefix is adopted by an owner or
  admin, or requested by a member and adopted on approval.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.TopologyFixtures

  alias Renga.Findings
  alias Renga.IPAM
  alias Renga.IPAM.AddressFinding
  alias Renga.Repo
  alias Renga.Requests

  setup do
    organization = organization_fixture()
    {admin_conn, admin} = sign_in(organization, "admin")
    {member_conn, member} = sign_in(organization, "member")
    {web, ports} = device_fixture(admin, "server", "web-01", ~w(eth0))
    strict = prefix_fixture(admin, "192.0.2.0/24", %{strict: true})
    observed = address_fixture(admin, ports["eth0"], "192.0.2.5/24")
    {:ok, :ok} = IPAM.AddressFindings.reconcile(organization.id)
    finding = Repo.get_by!(AddressFinding, kind: "unmanaged_in_strict_prefix")

    %{
      admin_conn: admin_conn,
      admin: admin,
      member_conn: member_conn,
      member: member,
      web: web,
      strict: strict,
      observed: observed,
      finding: finding
    }
  end

  test "an address finding is drift with the shared workflow", context do
    assert {[finding], 1} = Findings.list_findings(context.member, domain: "address")
    assert %{group: "drift", resource: %{id: resource_id}, interface_name: "eth0"} = finding
    assert resource_id == context.web.id

    {:ok, _} = Findings.accept_exception(context.member, finding, %{"exception_reason" => "Lab"})
    assert {[], 0} = Findings.list_findings(context.member, domain: "address")

    # Released and re-observed later, the same identity keeps its exception.
    {:ok, managed} = IPAM.adopt_address(context.admin, context.observed.id)
    {:ok, _} = IPAM.release_address(context.admin, managed.id)

    assert {[%{state: :excepted, id: id}], 1} =
             Findings.list_findings(context.member, domain: "address", state: "excepted")

    refute id == finding.id
  end

  test "an admin opens the finding and adopts the address", context do
    {:ok, view, _html} = live(context.admin_conn, ~p"/inbox")

    assert has_element?(view, "#findings-#{context.finding.id}", "Unmanaged in strict prefix")
    view |> element("#finding-link-address-#{context.finding.id}") |> render_click()

    assert has_element?(view, "#finding-properties", "IP addresses")

    assert has_element?(
             view,
             "#address-finding-prefix[href='/network/prefixes/#{context.strict.id}']",
             "192.0.2.0/24"
           )

    assert has_element?(view, "#address-finding-addresses[href='/network/addresses?q=192.0.2.5']")
    refute has_element?(view, "#address-finding-request-form")

    view |> element("#address-finding-adopt") |> render_click()

    assert has_element?(view, "#flash-info", "192.0.2.5/24 adopted")
    assert has_element?(view, "#finding-state", "Resolved")
    refute has_element?(view, "#address-finding-adopt")
    assert Repo.reload!(context.finding).status == "resolved"
  end

  test "a member requests adoption, and approval adopts the address", context do
    {:ok, view, _html} =
      live(context.member_conn, ~p"/inbox?#{[finding: "address:#{context.finding.id}"]}")

    refute has_element?(view, "#address-finding-adopt")

    view
    |> form("#address-finding-request-form", adoption: %{reason: ""})
    |> render_submit()

    assert has_element?(view, "#address-finding-request-form", "say why this change is needed")

    view
    |> form("#address-finding-request-form", adoption: %{reason: "Static web server"})
    |> render_submit()

    assert has_element?(view, "#flash-info", "Adoption requested")
    assert has_element?(view, "#address-finding-request", "Managed")
    refute has_element?(view, "#address-finding-request-form")

    request =
      Requests.open_request(
        context.admin,
        context.web.id,
        "adoption",
        "address:#{context.observed.id}"
      )

    assert %{after_value: %{"address" => "192.0.2.5/24"}, before_value: %{"value" => "Observed"}} =
             request

    {:ok, admin_view, _html} =
      live(context.admin_conn, ~p"/inbox?#{[group: "requests", request: request.id]}")

    assert has_element?(admin_view, "#requests-#{request.id}", "Adopt 192.0.2.5/24 into IPAM")

    admin_view
    |> form("#request-decision-form", decision_form: %{note: ""})
    |> put_submitter("#request-approve")
    |> render_submit()

    assert has_element?(admin_view, "#request-status", "approved")
    assert IPAM.observed_address(context.admin, context.observed.id).managed?
    assert Repo.reload!(context.finding).status == "resolved"
  end

  test "an adoption request names an address on the requested resource", context do
    {other, other_ports} = device_fixture(context.admin, "server", "web-02", ~w(eth0))
    elsewhere = address_fixture(context.admin, other_ports["eth0"], "192.0.2.6/24")

    assert {:error, :invalid_address} =
             Requests.request_adoption(context.member, context.web, elsewhere.id, %{
               "reason" => "x"
             })

    assert {:error, :invalid_address} =
             Requests.request_adoption(context.member, other, "not-an-id", %{"reason" => "x"})

    # Owners adopt directly instead of requesting.
    assert {:error, :forbidden} =
             Requests.request_adoption(context.admin, context.web, context.observed.id, %{
               "reason" => "x"
             })
  end

  defp sign_in(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      build_conn()
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, Renga.Accounts.scope_for_user(user, organization.id)}
  end
end
