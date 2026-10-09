defmodule Renga.Catalog.MovesTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.CatalogFixtures
  import Renga.InventoryFixtures

  alias Renga.Catalog
  alias Renga.Catalog.Drafts
  alias Renga.Catalog.Moves
  alias Renga.Findings

  @templates [
    %{kind: "memory", name: "DIMM A1", position: "A1", attributes: %{"part_number" => "M-32G"}},
    %{kind: "memory", name: "DIMM A2", position: "A2", attributes: %{"part_number" => "M-32G"}},
    %{kind: "disk", name: "Bay 1", position: "Bay 1", attributes: %{"model" => "SSD-1"}},
    %{kind: "disk", name: "Bay 2", position: "Bay 2", attributes: %{"model" => "SSD-1"}}
  ]

  setup do
    organization = organization_fixture()

    scopes =
      Map.new(~w(admin member viewer), fn role ->
        user = user_fixture()
        organization_membership_fixture(user, organization, %{role: role})
        {String.to_atom(role), Renga.Accounts.scope_for_user(user, organization.id)}
      end)

    {server, expected} = assigned_server_fixture(scopes.admin, "move-01", @templates)
    hardware_type = Catalog.get_hardware_assignment(scopes.admin, server.id).hardware_type

    # Revision 2 drops Bay 2 and expects 64 GB modules in A2.
    {:ok, draft} = Drafts.start_draft(scopes.admin, hardware_type)
    bay2 = Enum.find(draft.component_templates, &(&1.name == "Bay 2"))
    a2 = Enum.find(draft.component_templates, &(&1.name == "DIMM A2"))
    {:ok, draft} = Drafts.delete_templates(scopes.admin, draft, [bay2.id])

    {:ok, draft} =
      Drafts.put_template_group(scopes.admin, draft, [a2.id], %{
        "kind" => "memory",
        "name_pattern" => "DIMM A2",
        "attributes" => %{"part_number" => "M-64G"}
      })

    {:ok, revision2} = Drafts.publish_draft(scopes.admin, draft)

    Map.merge(scopes, %{
      server: server,
      expected: expected,
      hardware_type: hardware_type,
      revision2: revision2
    })
  end

  test "a move carries local changes, gaps, and replacements to the new revision", context do
    %{admin: admin, server: server, expected: expected} = context

    {:ok, _} =
      Catalog.put_expected_component_exception(admin, server.id, %{
        "action" => "alter",
        "component_template_id" => expected["Bay 1"].component_template_id,
        "changes" => %{"attributes" => %{"model" => "SSD-2"}}
      })

    {:ok, _} =
      Catalog.put_expected_component_exception(admin, server.id, %{
        "action" => "suppress",
        "component_template_id" => expected["Bay 2"].component_template_id
      })

    {:ok, _} =
      Catalog.put_expected_component_exception(admin, server.id, %{
        "action" => "add",
        "kind" => "disk",
        "name" => "Bay 9",
        "changes" => %{"position" => "Bay 9"}
      })

    {:ok, _} =
      Catalog.confirm_replacement(
        admin,
        server.id,
        %{"component_template_id" => expected["DIMM A1"].component_template_id},
        %{"part_number" => "M-32G-B"}
      )

    a1_key =
      "assignment:#{expected["DIMM A1"].hardware_assignment_id}:template:#{expected["DIMM A1"].component_template_id}"

    {:ok, _gap} =
      Findings.accept_component_gap(context.member, server.id, a1_key, %{
        "exception_reason" => "RMA",
        "exception_expires_at" => DateTime.add(DateTime.utc_now(), 86_400)
      })

    assert {:ok, %{dropped: [dropped]}} =
             Catalog.move_hardware_revision(context.member, server.id, context.revision2.id)

    # Bay 2 is gone from revision 2, so suppressing it no longer means anything.
    assert dropped.action == "suppress"

    expected_now = Map.new(Catalog.list_expected_components(admin, server.id), &{&1.name, &1})
    assert Catalog.get_hardware_assignment(admin, server.id).catalog_type_revision.revision == 2
    assert Map.keys(expected_now) |> Enum.sort() == ["Bay 1", "Bay 9", "DIMM A1", "DIMM A2"]
    assert expected_now["Bay 1"].attributes["model"] == "SSD-2"
    assert expected_now["DIMM A2"].attributes["part_number"] == "M-64G"

    [confirmation] = Catalog.list_confirmed_components(admin, server.id)
    assert confirmation.component_template_id == expected_now["DIMM A1"].component_template_id
    assert confirmation.part_number == "M-32G-B"

    new_key =
      "assignment:#{expected_now["DIMM A1"].hardware_assignment_id}:template:#{expected_now["DIMM A1"].component_template_id}"

    assert Map.has_key?(
             Findings.component_exceptions(admin, server.id),
             {"missing_expected_component", new_key}
           )

    assert {:error, :forbidden} =
             Catalog.move_hardware_revision(context.viewer, server.id, context.revision2.id)
  end

  test "previews the differences a move opens and closes, and moves in bulk", context do
    %{admin: admin, server: server} = context

    for slot <- ~w(A1 A2),
        do: actual_component_fixture(admin, server, "memory", slot, part_number: "M-64G")

    actual_component_fixture(admin, server, "disk", "Bay 1", model: "SSD-1")

    {other, _} = assigned_server_fixture(admin, "move-02", [])
    _ = other

    assert [entry] = Moves.preview(admin, context.hardware_type.id, context.revision2)
    assert entry.resource.id == server.id
    assert entry.revision == 1
    # Now: A1 and A2 differ (64 GB parts), Bay 2 is missing. On revision 2
    # A2 matches and Bay 2 is gone; A1 still differs.
    assert entry.close == 2
    assert entry.open == 0
    assert entry.dropped == 0
    refute Moves.fits_entry?(entry)

    assert {:ok, %{moved: 1}} = Moves.move(context.member, [server.id], context.revision2.id)
    assert Catalog.get_hardware_assignment(admin, server.id).catalog_type_revision.revision == 2
    assert {:error, :forbidden} = Moves.move(context.viewer, [server.id], context.revision2.id)
  end

  test "only owners and admins turn on automatic moves", context do
    assert {:error, :forbidden} =
             Catalog.set_auto_move(context.member, context.hardware_type, true)

    assert {:ok, %{auto_move: true}} =
             Catalog.set_auto_move(context.admin, context.hardware_type, true)
  end

  test "fit ignores satisfied local changes but not real drift", context do
    %{admin: scope, server: server, expected: expected} = context

    {:ok, _} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "alter",
        component_template_id: expected["DIMM A1"].component_template_id,
        changes: %{"attributes" => %{"part_number" => "LOCAL"}}
      })

    {:ok, _} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "suppress",
        component_template_id: expected["Bay 1"].component_template_id
      })

    {:ok, _} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "add",
        kind: "disk",
        name: "Bay 9",
        changes: %{"position" => "Bay 9"}
      })

    actual_component_fixture(scope, server, "memory", "A1", part_number: "LOCAL")
    actual_component_fixture(scope, server, "memory", "A2", part_number: "M-64G")
    actual_component_fixture(scope, server, "disk", "Bay 9")
    [entry] = Moves.preview(scope, context.hardware_type.id, context.revision2)
    assert Moves.fits_entry?(entry)
    assert entry.target.local_change == 0
    assignment = Catalog.get_hardware_assignment(scope, server.id)
    assert Moves.fits?(%{scope | user: nil}, assignment, context.revision2)
    {:ok, _} = Catalog.move_hardware_revision(scope, server.id, context.revision2.id)
    [entry] = Moves.preview(scope, context.hardware_type.id, context.revision2)
    assert entry.current == entry.target
    assert Moves.fits_entry?(entry)
  end

  test "preview and result count dropped confirmations as records", context do
    %{admin: scope, server: server, expected: expected} = context

    {:ok, exception} =
      Catalog.put_expected_component_exception(scope, server.id, %{
        action: "alter",
        component_template_id: expected["Bay 2"].component_template_id,
        changes: %{"attributes" => %{"model" => "Local"}}
      })

    {:ok, confirmation} =
      Catalog.confirm_replacement(
        scope,
        server.id,
        %{"exception_id" => exception.id},
        %{"model" => "Confirmed"}
      )

    [entry] = Moves.preview(scope, context.hardware_type.id, context.revision2)
    assert entry.dropped == 2

    {:ok, %{dropped: dropped}} =
      Catalog.move_hardware_revision(scope, server.id, context.revision2.id)

    assert length(dropped) == 2
    assert Enum.any?(dropped, &(&1.id == confirmation.id))
    assert Catalog.list_confirmed_components(scope, server.id) == []
  end

  test "backwards moves are rejected without changing expectations or workflows", context do
    scope = context.admin
    old_revision = Catalog.get_hardware_assignment(scope, context.server.id).catalog_type_revision
    {:ok, _} = Catalog.move_hardware_revision(scope, context.server.id, context.revision2.id)
    before = Catalog.list_expected_components(scope, context.server.id)

    assert {:error, :older_revision} =
             Catalog.move_hardware_revision(scope, context.server.id, old_revision.id)

    assert {:error, :older_revision} = Moves.move(scope, [context.server.id], old_revision.id)
    assert Catalog.list_expected_components(scope, context.server.id) == before
  end

  test "bulk move rolls back a valid first resource when the second has another type", context do
    scope = context.admin
    {other, _} = assigned_server_fixture(scope, "other-type", [])
    before = Catalog.list_expected_components(scope, context.server.id)

    assert {:error, :revision_not_found} =
             Moves.move(scope, [context.server.id, other.id], context.revision2.id)

    assert Catalog.get_hardware_assignment(scope, context.server.id).catalog_type_revision.revision ==
             1

    assert Catalog.list_expected_components(scope, context.server.id) == before
    {:ok, draft} = Drafts.start_draft(scope, context.hardware_type)

    assert {:error, :revision_not_found} =
             Catalog.move_hardware_revision(scope, context.server.id, draft.id)
  end

  test "local names colliding with target templates block preview and single or bulk moves",
       context do
    scope = context.admin
    {:ok, other} = Renga.Inventory.create_resource(scope, %{kind: "server", name: "valid-first"})
    {:ok, _} = Catalog.assign_hardware_type(scope, other.id, context.hardware_type.id)

    {:ok, _} =
      Catalog.put_expected_component_exception(scope, context.server.id, %{
        action: "add",
        kind: "interface",
        name: "eth1",
        changes: %{}
      })

    {:ok, draft} = Drafts.start_draft(scope, context.hardware_type)

    {:ok, draft} =
      Drafts.put_template_group(scope, draft, [], %{
        "kind" => "interface",
        "name_pattern" => "eth1"
      })

    {:ok, target} = Drafts.publish_draft(scope, draft)

    [entry] =
      Moves.preview(scope, context.hardware_type.id, target, resource_ids: [context.server.id])

    assert entry.conflicts == [{"interface", "eth1"}]
    refute Moves.fits_entry?(entry)
    before = Catalog.list_expected_components(scope, context.server.id)

    assert {:error, :expectation_conflict} =
             Catalog.move_hardware_revision(scope, context.server.id, target.id)

    assert {:error, :expectation_conflict} =
             Moves.move(scope, [other.id, context.server.id], target.id)

    assert Catalog.get_hardware_assignment(scope, other.id).catalog_type_revision.revision == 2
    assert Catalog.list_expected_components(scope, context.server.id) == before
  end
end
