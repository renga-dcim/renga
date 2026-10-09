defmodule Renga.Accounts.AppearanceTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Accounts.Appearance

  setup do
    organization = organization_fixture()

    scopes =
      Map.new(~w(owner admin member), fn role ->
        user = user_fixture()
        organization_membership_fixture(user, organization, %{role: role})
        {String.to_atom(role), Accounts.scope_for_user(user, organization.id)}
      end)

    Map.put(scopes, :organization, organization)
  end

  test "a person's preferences are saved and validated", %{member: member} do
    assert %Appearance{theme: "system", accent: "copper", density: "comfortable"} =
             Appearance.for_scope(member)

    assert {:ok, user} =
             Accounts.update_user_appearance(member.user, %{
               "theme" => "dark",
               "accent" => "iris",
               "density" => "compact"
             })

    assert %Appearance{theme: "dark", accent: "iris", density: "compact"} =
             Appearance.for_scope(%{member | user: user})

    assert {:error, changeset} =
             Accounts.update_user_appearance(user, %{"theme" => "neon", "accent" => "lime"})

    assert %{theme: [_], accent: [_]} = errors_on(changeset)

    # A blank accent goes back to following the organization.
    assert {:ok, %{accent: nil}} = Accounts.update_user_appearance(user, %{"accent" => ""})
  end

  test "owners change the organization's default accent; others cannot", context do
    assert {:error, :forbidden} = Accounts.set_default_accent(context.admin, "petrol")
    assert {:error, :forbidden} = Accounts.set_default_accent(context.member, "petrol")
    assert {:ok, organization} = Accounts.set_default_accent(context.owner, "petrol")
    assert organization.default_accent == "petrol"
    assert {:error, %Ecto.Changeset{}} = Accounts.set_default_accent(context.owner, "lime")

    # Members who have not chosen follow it; those who have keep theirs.
    member = Accounts.scope_for_user(context.member.user, context.organization.id)
    assert Appearance.for_scope(member).accent == "petrol"

    {:ok, user} = Accounts.update_user_appearance(member.user, %{"accent" => "cobalt"})
    assert Appearance.for_scope(%{member | user: user}).accent == "cobalt"
  end

  test "without a user, the defaults apply" do
    assert %Appearance{theme: "system", accent: "copper", density: "comfortable"} =
             Appearance.for_scope(nil)
  end
end
