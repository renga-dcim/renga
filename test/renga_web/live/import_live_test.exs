defmodule RengaWeb.ImportLiveTest do
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.Organization
  alias Renga.Jobs
  alias Renga.Repo
  alias Renga.Transfers.OrganizationImport

  defp member_conn(conn, role) do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: role})

    conn =
      conn
      |> log_in_user(user)
      |> put_session(:current_organization_id, organization.id)

    {conn, organization}
  end

  defp import_fixture(organization, held) do
    Repo.insert!(%OrganizationImport{
      organization_id: organization.id,
      source_organization_id: Ecto.UUID.generate(),
      source_slug: "acme",
      source_name: "Acme",
      format_version: 1,
      renga_version: "0.1.0",
      snapshot_at: Renga.Time.utc_now_ms(),
      records: 1,
      sha256: String.duplicate("0", 64),
      held_settings: held
    })
  end

  test "an owner confirms one held setting and dismisses another", %{conn: conn} do
    {conn, organization} = member_conn(conn, "owner")
    operate = Jobs.Registry.keys_with_risk(:operate) |> List.first()
    {:ok, capability} = Jobs.Registry.fetch(operate)

    import =
      import_fixture(organization, %{
        "jobs" => %{"allowed_capabilities" => [operate]},
        "unknown" => true
      })

    {:ok, view, _html} = live(conn, ~p"/settings/import")

    assert has_element?(view, "#import-#{import.id}", "From Acme")
    assert has_element?(view, "#held-#{import.id}-0", "Allow #{capability.title()}")
    assert has_element?(view, "#held-#{import.id}-1", "This version of Renga cannot apply it.")
    refute has_element?(view, "#held-#{import.id}-1-confirm")

    view |> element("#confirm-held-#{import.id}-0-confirm") |> render_click()

    assert render(view) =~ "Applied: Allow #{capability.title()}."
    assert operate in Jobs.Settings.allowed_capabilities(Repo.get!(Organization, organization.id))
    assert has_element?(view, "#held-#{import.id}-0", "Setting unknown")

    view |> element("#held-#{import.id}-0-dismiss") |> render_click()

    assert has_element?(view, "#import-none")
    assert Repo.get!(OrganizationImport, import.id).held_settings == %{}
  end

  test "malformed imported settings render dismiss-only and can be cleared", %{conn: conn} do
    {conn, organization} = member_conn(conn, "owner")

    for capabilities <- [[%{}], [["nested"]], [42]] do
      import =
        import_fixture(organization, %{
          "jobs" => %{"allowed_capabilities" => capabilities},
          "security" => %{"require_mfa" => "off"},
          String.duplicate("unknown", 50) => false
        })

      {:ok, view, _html} = live(conn, ~p"/settings/import")

      for index <- 0..2 do
        assert has_element?(view, "#held-#{import.id}-#{index}")
        refute has_element?(view, "#held-#{import.id}-#{index}-confirm")
      end

      for _ <- 0..2,
          do: view |> element("#held-#{import.id}-0-dismiss") |> render_click()

      assert has_element?(view, "#import-none")
      assert Repo.get!(OrganizationImport, import.id).held_settings == %{}
    end
  end

  test "people who cannot change settings see neither imports nor actions", %{conn: conn} do
    {conn, organization} = member_conn(conn, "admin")
    import = import_fixture(organization, %{"unknown" => true})

    {:ok, view, _html} = live(conn, ~p"/settings/import")

    assert has_element?(view, "#import-owners-only")
    refute has_element?(view, "#import-#{import.id}")
  end
end
