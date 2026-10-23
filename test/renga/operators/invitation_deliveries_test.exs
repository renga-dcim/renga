defmodule Renga.Operators.InvitationDeliveriesTest do
  use Renga.DataCase, async: false

  import Renga.InventoryFixtures

  alias Renga.Accounts.OrganizationInvitation
  alias Renga.Operators
  alias Renga.Operators.InvitationDeliveries
  alias Renga.Operators.InvitationDelivery
  alias Renga.Operators.InvitationDeliveryWorker
  alias Renga.Operators.Organizations
  alias Renga.Repo

  setup do
    organization = organization_fixture(%{name: "Acme"})

    {:ok, {token, _plaintext}} =
      Operators.create_token(
        %{name: "cloud", scopes: ["organizations:write"]},
        Renga.DeploymentAudit.operator("test")
      )

    context = Renga.DeploymentAudit.token(token, Ecto.UUID.generate())
    %{context: context, organization: organization}
  end

  test "an outer rollback sends nothing and leaves no delivery intent", context do
    %{context: operator, organization: organization} = context

    assert {:error, :fault_after_mutation} =
             Repo.transaction(fn ->
               assert {:ok, _invitation} =
                        Organizations.invite_owner(
                          organization.id,
                          "owner@acme.test",
                          operator,
                          &"https://renga.test/invitations/#{&1}"
                        )

               refute_received {:email, _}
               Repo.rollback(:fault_after_mutation)
             end)

    refute Repo.get_by(OrganizationInvitation, email: "owner@acme.test")
    assert Repo.aggregate(InvitationDelivery, :count) == 0
    refute_received {:email, _}
  end

  test "a committed intent survives until a sweep delivers its one invitation", context do
    invitation = queue_without_dispatch(context)

    assert %InvitationDelivery{attempts: 0, url_ciphertext: ciphertext} =
             Repo.get_by!(InvitationDelivery, invitation_id: invitation.id)

    assert :binary.match(ciphertext, "https://renga.test") == :nomatch
    refute_received {:email, _}

    assert %{delivered: 1, pending: 0, discarded: 0} = InvitationDeliveries.sweep()
    assert_received {:email, %{text_body: body}}
    assert body =~ "https://renga.test/invitations/"
    refute Repo.get_by(InvitationDelivery, invitation_id: invitation.id)
  end

  test "an ambiguous provider result retries the same encrypted link", context do
    mailer_config = Application.fetch_env!(:renga, Renga.Mailer)
    on_exit(fn -> Application.put_env(:renga, Renga.Mailer, mailer_config) end)
    Application.put_env(:renga, Renga.Mailer, adapter: Renga.AmbiguousMailerAdapter)

    invitation = queue_without_dispatch(context)

    assert %{delivered: 0, pending: 1, discarded: 0} = InvitationDeliveries.sweep()
    assert_received {:ambiguous_email, %{text_body: first_body}}

    assert %InvitationDelivery{attempts: 1} =
             Repo.get_by!(InvitationDelivery, invitation_id: invitation.id)

    Application.put_env(:renga, Renga.Mailer, mailer_config)
    later = DateTime.add(Renga.Time.utc_now_ms(), 10, :second)

    assert %{delivered: 1, pending: 0, discarded: 0} = InvitationDeliveries.sweep(later)
    assert_received {:email, %{text_body: second_body}}
    assert invitation_url(first_body) == invitation_url(second_body)
    refute Repo.get_by(InvitationDelivery, invitation_id: invitation.id)
  end

  test "the recovery worker sweeps immediately and on its interval" do
    parent = self()

    start_supervised!(
      {InvitationDeliveryWorker, name: nil, interval: 10, sweep: fn -> send(parent, :swept) end}
    )

    assert_receive :swept
    assert_receive :swept
  end

  defp queue_without_dispatch(%{context: context, organization: organization}) do
    assert {:ok, {:ok, invitation}} =
             Repo.transaction(fn ->
               Organizations.invite_owner(
                 organization.id,
                 "owner@acme.test",
                 context,
                 &"https://renga.test/invitations/#{&1}"
               )
             end)

    invitation
  end

  defp invitation_url(body) do
    [url] = Regex.run(~r{https://renga\.test/invitations/\S+}, body)
    url
  end
end
