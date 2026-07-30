defmodule RengaWeb.CurrentScopeTest do
  use RengaWeb.ConnCase, async: true

  alias Renga.Accounts
  alias RengaWeb.CurrentScope

  describe "controller scope helpers" do
    test "put_current_organization/2 stores and assigns the current organization", %{conn: conn} do
      {:ok, organization} =
        Accounts.create_organization(%{
          name: "Acme Operations",
          slug: "acme-ops"
        })

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> CurrentScope.put_current_organization(organization)

      assert get_session(conn, "current_organization_id") == organization.id
      assert conn.assigns.current_scope.organization_id == organization.id
    end

    test "fetch_current_scope/2 assigns nil when the session has no organization", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> CurrentScope.fetch_current_scope([])

      assert conn.assigns.current_scope == nil
    end

    test "fetch_current_scope/2 loads organization scope from session", %{conn: conn} do
      {:ok, organization} =
        Accounts.create_organization(%{
          name: "Acme Operations",
          slug: "acme-ops"
        })

      conn =
        conn
        |> Plug.Test.init_test_session(%{"current_organization_id" => organization.id})
        |> CurrentScope.fetch_current_scope([])

      assert conn.assigns.current_scope.organization_id == organization.id
    end

    test "clear_current_organization/1 removes the session and assigned scope", %{conn: conn} do
      {:ok, organization} =
        Accounts.create_organization(%{
          name: "Acme Operations",
          slug: "acme-ops"
        })

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> CurrentScope.put_current_organization(organization)
        |> CurrentScope.clear_current_organization()

      assert get_session(conn, "current_organization_id") == nil
      assert conn.assigns.current_scope == nil
    end
  end
end
