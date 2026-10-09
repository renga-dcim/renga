defmodule RengaWeb.CatalogDraftLiveTest do
  @moduledoc """
  Editing a hardware type as a draft: autosaved fields, key/value rows,
  template groups by pattern, review with impact, publish and discard.
  """
  use RengaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.Catalog.Drafts

  @dimms for bank <- ~w(A B),
             n <- 1..2,
             do: %{
               kind: "memory",
               name: "DIMM #{bank}#{n}",
               position: "#{bank}#{n}",
               attributes: %{"part_number" => "M-32G"}
             }

  setup %{conn: conn} do
    organization = organization_fixture()
    admin = scope_for(organization, "member")
    {server, _expected} = assigned_server_fixture(admin, "draft-ui", @dimms)

    for slot <- ~w(A1 A2 B1 B2),
        do: actual_component_fixture(admin, server, "memory", slot, part_number: "M-32G")

    hardware_type = Catalog.get_hardware_assignment(admin, server.id).hardware_type

    %{
      conn: log_in(conn, admin, organization),
      organization: organization,
      scope: admin,
      server: server,
      hardware_type: hardware_type
    }
  end

  test "editing a type starts a draft copied from its latest revision", context do
    {:ok, view, _html} = live(context.conn, ~p"/catalog/hardware-types/#{context.hardware_type}")

    # Hardware types publish through drafts, not the one-shot form.
    refute has_element?(view, "#new-revision-form")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#draft-start") |> render_click()

    assert to == "/catalog/hardware-types/#{context.hardware_type.id}/draft"
    {:ok, draft_view, _html} = live(context.conn, to)

    assert has_element?(draft_view, "#draft-templates", "DIMM {A,B}{1..2}")
    assert has_element?(draft_view, "#catalog-draft", "Draft revision 2")

    {:ok, view, _html} = live(context.conn, ~p"/catalog/hardware-types/#{context.hardware_type}")
    assert has_element?(view, "#draft-continue")
  end

  test "revision fields and specifications save as they are typed", context do
    {:ok, draft} = Drafts.start_draft(context.scope, context.hardware_type)
    {:ok, view, _html} = live(context.conn, draft_path(context))

    view
    |> form("#draft-form", draft: %{part_number: "R760", height_units: "2"})
    |> render_change()

    assert has_element?(view, "#draft-saved", "Saved")

    assert %{part_number: "R760", height_units: 2} =
             Drafts.get_draft(context.scope, context.hardware_type)

    view |> form("#draft-form", draft: %{height_units: "-1"}) |> render_change()
    assert has_element?(view, "#draft-form [role=alert]")

    view |> element("#add-spec-row") |> render_click()
    view |> element("#add-spec-row") |> render_click()

    render_change(view, "save_specs", %{
      "specs" => %{
        "0" => %{"key" => "cpu_sockets", "value" => "2"},
        "1" => %{"key" => "bmc", "value" => "iDRAC9"}
      }
    })

    assert Drafts.get_draft(context.scope, context.hardware_type).specifications ==
             %{"cpu_sockets" => 2, "bmc" => "iDRAC9"}

    # Removing the first row keeps the second.
    view |> element("#specs-row-0-remove") |> render_click()

    assert Drafts.get_draft(context.scope, context.hardware_type).specifications ==
             %{"bmc" => "iDRAC9"}

    _draft = draft
  end

  test "template groups are added, edited, and removed by pattern", context do
    {:ok, _draft} = Drafts.start_draft(context.scope, context.hardware_type)
    {:ok, view, _html} = live(context.conn, draft_path(context) <> "?group=new")

    view
    |> form("#group-form", group: %{kind: "disk", name_pattern: "Bay {1..2"})
    |> render_change()

    assert has_element?(view, "#group-preview", "braces")

    view
    |> form("#group-form", group: %{kind: "disk", name_pattern: "Bay {1..4}"})
    |> render_change()

    assert has_element?(view, "#group-preview", "4 templates: Bay 1, Bay 2, Bay 3, Bay 4")
    assert has_element?(view, "#group-explanation", "slot is {1..4}")

    view |> element("#add-attribute-row") |> render_click()

    view
    |> form("#group-form",
      group: %{
        kind: "disk",
        name_pattern: "Bay {1..4}",
        attributes: %{"0" => %{key: "model", value: "PM9A3"}}
      }
    )
    |> render_submit()

    refute has_element?(view, "#group-panel")
    assert has_element?(view, "#draft-templates", "Bay {1..4}")
    assert has_element?(view, "#draft-templates", "model=PM9A3")

    draft = Drafts.get_draft(context.scope, context.hardware_type)
    bay = Enum.find(draft.component_templates, &(&1.name == "Bay 1"))
    assert bay.attributes == %{"model" => "PM9A3"}
    assert bay.position == "1"

    {:ok, view, _html} = live(context.conn, draft_path(context) <> "?group=#{bay.id}")
    assert has_element?(view, "#group-form input[name='group[name_pattern]'][value='Bay {1..4}']")

    view
    |> form("#group-form", group: %{name_pattern: "DIMM A1", kind: "memory"})
    |> render_submit()

    assert has_element?(view, "#group-form", "already a template")

    view |> element("#group-delete") |> render_click()
    refute has_element?(view, "#draft-templates", "Bay {1..4}")
  end

  test "review lists the changes and the impact, and publishing moves nothing", context do
    {:ok, draft} = Drafts.start_draft(context.scope, context.hardware_type)
    b = Enum.filter(draft.component_templates, &String.starts_with?(&1.name, "DIMM B"))

    {:ok, _draft} =
      Drafts.put_template_group(context.scope, draft, Enum.map(b, & &1.id), %{
        "kind" => "memory",
        "name_pattern" => "DIMM B{1..2}",
        "attributes" => %{"part_number" => "M-64G"}
      })

    {:ok, view, _html} = live(context.conn, draft_path(context) <> "?review=1")

    assert has_element?(view, "#review-changes [data-change=changed]", "DIMM B{1..2}")
    assert has_element?(view, "#review-impact-summary", "1 resource")

    assert has_element?(
             view,
             "#impact-#{context.server.id}[data-fits=false]",
             "0 differences now → 2"
           )

    assert {:error, {:live_redirect, %{to: to, flash: _flash}}} =
             view |> element("#review-publish") |> render_click()

    assert to == "/catalog/hardware-types/#{context.hardware_type.id}"
    assert is_nil(Drafts.get_draft(context.scope, context.hardware_type))

    assert Catalog.get_hardware_assignment(context.scope, context.server.id).catalog_type_revision.revision ==
             1
  end

  test "a draft can be discarded", context do
    {:ok, _draft} = Drafts.start_draft(context.scope, context.hardware_type)
    {:ok, view, _html} = live(context.conn, draft_path(context))

    assert {:error, {:live_redirect, _redirect}} = render_click(view, "discard", %{})
    assert is_nil(Drafts.get_draft(context.scope, context.hardware_type))
  end

  test "viewers read the type but cannot edit, even with forged events", context do
    {:ok, _draft} = Drafts.start_draft(context.scope, context.hardware_type)
    viewer = scope_for(context.organization, "viewer")
    conn = log_in(build_conn(), viewer, context.organization)

    {:ok, view, _html} = live(conn, draft_path(context))
    assert has_element?(view, "#draft-read-only")
    refute has_element?(view, "#draft-editor")

    render_click(view, "publish", %{})
    render_change(view, "save_draft", %{"draft" => %{"part_number" => "forged"}})

    assert %{part_number: nil} = Drafts.get_draft(context.scope, context.hardware_type)
  end

  defp draft_path(context), do: ~p"/catalog/hardware-types/#{context.hardware_type}/draft"

  defp scope_for(organization, role) do
    user = user_fixture()
    organization_membership_fixture(user, organization, %{role: role})
    Renga.Accounts.scope_for_user(user, organization.id)
  end

  defp log_in(conn, scope, organization) do
    conn
    |> log_in_user(scope.user)
    |> put_session(:current_organization_id, organization.id)
  end
end
