defmodule Renga.Transfers.PrincipalsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.JobsFixtures

  alias Renga.Accounts.OrganizationMembership
  alias Renga.Assignments
  alias Renga.Inventory
  alias Renga.Members
  alias Renga.Roles.Assignment
  alias Renga.SavedViews
  alias Renga.SavedViews.SavedView
  alias Renga.Teams
  alias Renga.Teams.TeamMembership
  alias Renga.Transfers.Export
  alias Renga.Transfers.Import
  alias Renga.Transfers.ImportedPrincipal
  alias Renga.Transfers.Principals

  @moduletag :tmp_dir

  # A source with an admin, Ada, who has a team, two current assignments
  # (one an admin could not grant) and an expired one, a private view, and
  # a shared view Ada made; and Bo, a disabled member. The source is exported, removed, and imported into a
  # target whose owner then invites people back.
  setup %{tmp_dir: tmp_dir} do
    source = Renga.InventoryFixtures.organization_fixture()
    owner = member_scope(source, "owner")
    ada = member_scope(source, "admin")
    bo = member_scope(source, "member")

    {:ok, team} = Teams.create_team(owner, %{name: "Network"})
    {:ok, _team_membership} = Teams.add_member(owner, team, ada.membership_id)
    {:ok, current} = Assignments.assign(owner, ada.membership_id, %{"role" => "viewer"})
    {:ok, above_admin} = Assignments.assign(owner, ada.membership_id, %{"role" => "owner"})

    {:ok, expired} =
      Assignments.assign(owner, ada.membership_id, %{
        "role" => "member",
        "valid_until" => DateTime.add(DateTime.utc_now(), 1, :day)
      })

    Repo.update_all(where(Assignment, id: ^expired.id),
      set: [valid_until: DateTime.add(Renga.Time.utc_now_ms(), -1, :day)]
    )

    {:ok, mine} = SavedViews.create_view(ada, %{area: "inventory", name: "Mine"})
    {:ok, ours} = SavedViews.create_view(ada, %{area: "inventory", name: "Ours", shared: true})
    {:ok, _bo} = Members.disable_member(owner, bo.membership_id)

    path = Path.join(tmp_dir, "source.tar.zst")
    {:ok, _summary} = Export.write(source, path, parts: ~w(history))
    Repo.delete!(source)

    target = Renga.InventoryFixtures.organization_fixture()
    target_owner = member_scope(target, "owner")

    {:ok, _import} =
      Import.run(target, path,
        imported_by_user_id: target_owner.user.id,
        operator: "ops@example.com",
        tmp_dir: tmp_dir
      )

    %{
      target: target,
      inviter: target_owner,
      ada: ada,
      bo: bo,
      team: team,
      current: current,
      expired: expired,
      mine: mine,
      ours: ours,
      above_admin: above_admin
    }
  end

  defp principal(context, scope),
    do:
      Repo.get_by!(ImportedPrincipal,
        organization_id: context.target.id,
        source_id: scope.user.id
      )

  defp invite(context, scope),
    do:
      Principals.invite(
        context.inviter,
        principal(context, scope).id,
        &"https://renga.test/invitations/#{&1}"
      )

  defp token_from_email do
    assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
    [_, token] = Regex.run(~r{/invitations/(\S+)}, body)
    token
  end

  defp restored_assignments(membership_id),
    do: Repo.all(from a in Assignment, where: a.membership_id == ^membership_id, select: a.id)

  test "only active members with an email can come back, with their role", context do
    returning =
      context.inviter
      |> Principals.list_unlinked()
      |> Map.new(&{&1.principal.source_id, &1.role})

    assert returning[context.ada.user.id] == "admin"
    assert Map.has_key?(returning, context.bo.user.id)
    assert returning[context.bo.user.id] == nil

    assert {:error, :not_eligible} = invite(context, context.bo)
    refute_received {:email, %{subject: "You're invited" <> _}}
  end

  test "managed access cannot return through either invitation creation or acceptance", context do
    assert {:ok, _invitation} = invite(context, context.ada)
    token = token_from_email()
    principal = principal(context, context.ada)

    for metadata <- [
          %{"managed_by" => "scim"},
          %{"managed_by" => nil},
          %{"managed_by" => false},
          42,
          "unexpected",
          [%{}]
        ] do
      Repo.query!(
        """
        UPDATE imported_held_records SET record = jsonb_set(record, '{metadata}', $2::jsonb)
        WHERE principal_id = $1 AND record_type = 'organization_memberships'
        """,
        [Ecto.UUID.dump!(principal.id), metadata]
      )

      assert %{role: nil} =
               Enum.find(
                 Principals.list_unlinked(context.inviter),
                 &(&1.principal.id == principal.id)
               )

      assert {:error, :not_eligible} = invite(context, context.ada)
      refute Principals.invitable?(context.target.id, principal.id, principal.email)
      assert {:error, :invalid} = Members.accept_invitation(context.ada.user, token)
      refute Repo.get(OrganizationMembership, context.ada.membership_id)
      assert Repo.get!(ImportedPrincipal, principal.id).user_id == nil
    end
  end

  test "accepting links the person and restores what they had", context do
    assert {:ok, invitation} = invite(context, context.ada)
    assert invitation.role == "admin"
    assert invitation.email == context.ada.user.email

    assert {:ok, membership} = Members.accept_invitation(context.ada.user, token_from_email())

    # The membership keeps its ID, so the team and assignment refer to it.
    assert membership.id == context.ada.membership_id
    assert {membership.role, membership.status} == {"admin", "active"}
    assert Repo.exists?(where(TeamMembership, membership_id: ^membership.id))

    # Only the assignments that are still valid come back; the expired one
    # stays held.
    assert membership.id |> restored_assignments() |> Enum.sort() ==
             Enum.sort([context.current.id, context.above_admin.id])

    # The private view is hers again, and the shared view names her.
    assert %SavedView{user_id: user_id} = Repo.get!(SavedView, context.mine.id)
    assert user_id == context.ada.user.id
    assert Repo.get!(SavedView, context.ours.id).created_by_id == context.ada.user.id

    principal = principal(context, context.ada)
    assert principal.user_id == context.ada.user.id
    assert %DateTime{} = principal.linked_at

    assert [["role_assignments"]] =
             Repo.query!(
               "SELECT record_type FROM imported_held_records WHERE principal_id = $1",
               [Ecto.UUID.dump!(principal.id)]
             ).rows

    assert [joined] =
             context.inviter
             |> Inventory.list_activity()
             |> Enum.filter(&(&1.kind == "member_joined"))

    assert joined.metadata["imported_principal_id"] == principal.id

    assert joined.metadata["restored"] == %{
             "role_assignments" => 2,
             "saved_views" => 1,
             "team_memberships" => 1
           }

    assert Principals.list_unlinked(context.inviter)
           |> Enum.all?(&(&1.principal.id != principal.id))
  end

  test "a principal links once", context do
    assert {:ok, _invitation} = invite(context, context.ada)
    token = token_from_email()

    principal(context, context.ada)
    |> Ecto.Changeset.change(user_id: user_fixture().id)
    |> Repo.update!()

    assert {:error, :invalid} = Members.accept_invitation(context.ada.user, token)
    refute Repo.get(OrganizationMembership, context.ada.membership_id)
    assert {:error, :not_found} = invite(context, context.ada)
  end

  test "an invitation brings a person back only at their own address", context do
    principal = principal(context, context.ada)
    url = &"https://renga.test/invitations/#{&1}"

    assert {:error, changeset} =
             Members.invite(
               context.inviter,
               %{"email" => "someone@example.com", "role" => "admin"},
               url,
               imported_principal_id: principal.id
             )

    assert "is not the imported person's address" in errors_on(changeset).email
    refute_received {:email, %{subject: "You're invited" <> _}}

    # An invitation whose address no longer matches its person links no one.
    assert {:ok, invitation} = invite(context, context.ada)
    token = token_from_email()

    Repo.update_all(where(Renga.Accounts.OrganizationInvitation, id: ^invitation.id),
      set: [email: context.bo.user.email]
    )

    assert {:error, :invalid} = Members.accept_invitation(context.bo.user, token)
    assert Repo.get!(ImportedPrincipal, principal.id).user_id == nil
  end

  test "assignments come back only within what the inviter may grant when Ada accepts",
       context do
    admin = member_scope(context.target, "admin")

    assert {:ok, _invitation} =
             Principals.invite(
               admin,
               principal(context, context.ada).id,
               &"https://renga.test/invitations/#{&1}"
             )

    assert {:ok, membership} = Members.accept_invitation(context.ada.user, token_from_email())
    assert restored_assignments(membership.id) == [context.current.id]
  end

  test "an inviter demoted before Ada accepts restores only what they may still grant",
       context do
    co_owner = member_scope(context.target, "owner")
    inviter = member_scope(context.target, "owner")

    assert {:ok, _invitation} =
             Principals.invite(
               inviter,
               principal(context, context.ada).id,
               &"https://renga.test/invitations/#{&1}"
             )

    token = token_from_email()
    assert {:ok, _demoted} = Members.change_role(co_owner, inviter.membership_id, "admin")

    assert {:ok, membership} = Members.accept_invitation(context.ada.user, token)
    assert restored_assignments(membership.id) == [context.current.id]
  end

  test "an invitation from someone disabled or gone since links no one", context do
    co_owner = member_scope(context.target, "owner")
    principal = principal(context, context.ada)

    for leave <- [
          &Members.disable_member(co_owner, &1.membership_id),
          &Repo.delete(&1.user)
        ] do
      inviter = member_scope(context.target, "owner")

      assert {:ok, _invitation} =
               Principals.invite(inviter, principal.id, &"https://renga.test/invitations/#{&1}")

      token = token_from_email()
      assert {:ok, _left} = leave.(inviter)

      assert {:error, :forbidden} = Members.accept_invitation(context.ada.user, token)
      assert Repo.get!(ImportedPrincipal, principal.id).user_id == nil
    end
  end

  test "linking never fills history or cable claims" do
    fillable = Principals.fillable()

    refute {"cable_assertions", "actor_user_id"} in fillable
    refute {"change_events", "actor_user_id"} in fillable
    refute {"job_events", "actor_id"} in fillable
    assert {"finding_workflows", "assignee_user_id"} in fillable
  end
end
