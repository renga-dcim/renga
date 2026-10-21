defmodule Renga.MembersDeliveryTest do
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures
  import Renga.JobsFixtures, only: [member_scope: 2]

  alias Renga.Inventory
  alias Renga.Members

  test "a failed delivery is reported and can be retried" do
    organization = organization_fixture()
    owner = member_scope(organization, "owner")
    recipient = user_fixture()
    mailer_config = Application.fetch_env!(:renga, Renga.Mailer)

    on_exit(fn -> Application.put_env(:renga, Renga.Mailer, mailer_config) end)
    Application.put_env(:renga, Renga.Mailer, adapter: Renga.FailingMailerAdapter)

    assert {:error, {:delivery_failed, failed_invitation}} =
             Members.invite(
               owner,
               %{"email" => recipient.email, "role" => "viewer"},
               &"https://renga.test/invitations/#{&1}"
             )

    assert [%{id: id}] = Members.list_invitations(owner)
    assert id == failed_invitation.id
    assert [%{kind: "member_invited"}] = Inventory.list_activity(owner)

    Application.put_env(:renga, Renga.Mailer, mailer_config)

    assert {:ok, replacement} =
             Members.invite(
               owner,
               %{"email" => recipient.email, "role" => "viewer"},
               &"https://renga.test/invitations/#{&1}"
             )

    assert replacement.id != failed_invitation.id

    kinds = owner |> Inventory.list_activity() |> Enum.frequencies_by(& &1.kind)
    assert kinds == %{"invitation_revoked" => 1, "member_invited" => 2}
  end
end
