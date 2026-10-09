defmodule Renga.Catalog.DraftsTest do
  use Renga.DataCase, async: true

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

  setup do
    organization = organization_fixture()

    scopes =
      Map.new(~w(admin member viewer), fn role ->
        user = user_fixture()
        organization_membership_fixture(user, organization, %{role: role})
        {String.to_atom(role), Renga.Accounts.scope_for_user(user, organization.id)}
      end)

    {server, _expected} = assigned_server_fixture(scopes.admin, "draft-01", @dimms)
    hardware_type = Catalog.get_hardware_assignment(scopes.admin, server.id).hardware_type
    Map.merge(scopes, %{server: server, hardware_type: hardware_type})
  end

  test "a draft copies the latest revision and only one is open per type", context do
    assert {:ok, draft} = Drafts.start_draft(context.member, context.hardware_type)
    assert draft.revision == 2
    assert is_nil(draft.finalized_at)
    assert length(draft.component_templates) == 4

    assert {:ok, same} = Drafts.start_draft(context.admin, context.hardware_type)
    assert same.id == draft.id
    assert Drafts.get_draft(context.admin, context.hardware_type).id == draft.id

    # Drafts stay off the type's published revisions.
    assert [%{revision: 1}] =
             Catalog.get_hardware_type!(context.admin, context.hardware_type.id).revisions

    assert {:error, :forbidden} = Drafts.start_draft(context.viewer, context.hardware_type)
  end

  test "edits revision fields and template groups by pattern", context do
    {:ok, draft} = Drafts.start_draft(context.admin, context.hardware_type)

    assert {:ok, draft} = Drafts.update_draft(context.admin, draft, %{"part_number" => "R760-XS"})
    assert draft.part_number == "R760-XS"

    old_ids = Enum.map(draft.component_templates, & &1.id)

    assert {:ok, draft} =
             Drafts.put_template_group(context.admin, draft, old_ids, %{
               "kind" => "memory",
               "name_pattern" => "DIMM {A,B}{1..4}",
               "required" => "true",
               "attributes" => %{"part_number" => "M-64G"}
             })

    assert length(draft.component_templates) == 8
    assert Enum.all?(draft.component_templates, &(&1.attributes == %{"part_number" => "M-64G"}))
    assert Enum.find(draft.component_templates, &(&1.name == "DIMM B3")).position == "B3"

    assert {:error, "braces" <> _rest} =
             Drafts.put_template_group(context.admin, draft, [], %{
               "kind" => "disk",
               "name_pattern" => "Bay {1..2"
             })

    assert {:error, "DIMM A1 is already a template in another group"} =
             Drafts.put_template_group(context.admin, draft, [], %{
               "kind" => "memory",
               "name_pattern" => "DIMM A1",
               "attributes" => %{}
             })

    disk_ids =
      draft
      |> then(
        &Drafts.put_template_group(context.admin, &1, [], %{
          "kind" => "disk",
          "name_pattern" => "Bay {1..2}",
          "attributes" => %{}
        })
      )
      |> then(fn {:ok, draft} -> draft.component_templates end)
      |> Enum.filter(&(&1.kind == "disk"))
      |> Enum.map(& &1.id)

    assert {:ok, draft} = Drafts.delete_templates(context.admin, draft, disk_ids)
    assert length(draft.component_templates) == 8
  end

  test "lists changes and the impact on resources using the type", context do
    {:ok, draft} = Drafts.start_draft(context.admin, context.hardware_type)
    {:ok, draft} = Drafts.update_draft(context.admin, draft, %{"height_units" => 2})

    a = Enum.filter(draft.component_templates, &String.starts_with?(&1.name, "DIMM A"))
    b = Enum.filter(draft.component_templates, &String.starts_with?(&1.name, "DIMM B"))

    {:ok, draft} =
      Drafts.put_template_group(context.admin, draft, Enum.map(b, & &1.id), %{
        "kind" => "memory",
        "name_pattern" => "DIMM B{1..2}",
        "attributes" => %{"part_number" => "M-64G"}
      })

    {:ok, draft} =
      Drafts.put_template_group(context.admin, draft, [], %{
        "kind" => "disk",
        "name_pattern" => "Bay 1",
        "attributes" => %{}
      })

    changes = Drafts.change_list(context.admin, draft)
    assert changes.fields == [{:height_units, nil, 2}]
    assert [%{name_pattern: "Bay 1"}] = changes.added
    assert changes.removed == []
    assert [{%{name_pattern: "DIMM B{1..2}"}, [:attributes]}] = changes.changed
    assert length(a) == 2

    for slot <- ~w(A1 A2 B1 B2),
        do:
          actual_component_fixture(context.admin, context.server, "memory", slot,
            part_number: "M-32G"
          )

    {:ok, unobserved} =
      Renga.Inventory.create_resource(context.admin, %{kind: "server", name: "draft-02"})

    {:ok, _assignment} =
      Catalog.assign_hardware_type(context.admin, unobserved.id, context.hardware_type.id)

    assert [observed, never] = Drafts.impact(context.admin, draft)
    assert observed.resource.id == context.server.id
    assert observed.revision == 1
    assert observed.current.match == 4
    assert observed.draft.local_change == 2
    assert observed.draft.missing == 1
    refute Drafts.fits?(observed)
    refute never.observed?
  end

  test "publishing freezes the draft without moving resources", context do
    {:ok, draft} = Drafts.start_draft(context.admin, context.hardware_type)

    # While a draft is open, the type publishes through it.
    assert {:error, :draft_open} =
             Catalog.create_hardware_type_revision(context.admin, context.hardware_type, %{}, [])

    assert {:ok, published} = Drafts.publish_draft(context.member, draft)
    assert published.revision == 2
    assert published.finalized_at
    assert is_nil(Drafts.get_draft(context.admin, context.hardware_type))

    assert Catalog.get_hardware_assignment(context.admin, context.server.id).catalog_type_revision.revision ==
             1

    assert {:error, :draft_closed} =
             Drafts.update_draft(context.admin, published, %{"part_number" => "x"})

    {:ok, again} = Drafts.start_draft(context.admin, context.hardware_type)
    assert {:ok, :discarded} = Drafts.discard_draft(context.admin, again)
    assert is_nil(Drafts.get_draft(context.admin, context.hardware_type))
  end
end
