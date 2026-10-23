defmodule Renga.Accounts.OrganizationDomainsTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.OrganizationDomain
  alias Renga.Accounts.OrganizationDomains
  alias Renga.Accounts.OrganizationProviders
  alias Renga.Accounts.Scope
  alias Renga.FakeTxtResolver
  alias Renga.Inventory.ChangeEvent
  alias RengaWeb.ChangeDescription

  defp scope(organization, role) do
    user = user_fixture()
    membership = organization_membership_fixture(user, organization, %{role: role})
    Scope.for_membership(user, organization, membership)
  end

  defp publish(claim) do
    FakeTxtResolver.put(OrganizationDomains.record_name(claim), [
      "v=spf1 -all",
      OrganizationDomains.record_value(claim)
    ])
  end

  defp verified(scope, domain) do
    {:ok, claim} = OrganizationDomains.add(scope, domain)
    publish(claim)
    {:ok, claim} = OrganizationDomains.verify(scope, claim)
    claim
  end

  defp active_provider(scope) do
    {:ok, {provider, _}} =
      OrganizationProviders.create(scope, %{
        "id" => OrganizationProviders.new_id(),
        "issuer" => "https://login.example.com",
        "display_name" => "Example SSO",
        "client_id" => "renga",
        "client_secret" => "s3cret"
      })

    provider
    |> Ecto.Changeset.change(active_revision: provider.pending_revision, pending_revision: nil)
    |> Repo.update!()
  end

  defp changes(organization) do
    Repo.all(
      from e in ChangeEvent,
        where: e.organization_id == ^organization.id and e.kind == "organization_domain_changed",
        order_by: [asc: e.occurred_at, asc: e.inserted_at]
    )
  end

  setup do
    organization = organization_fixture()
    %{organization: organization, owner: scope(organization, "owner")}
  end

  describe "add/2" do
    test "claims a normalized domain, unverified, with a record to publish", %{owner: owner} do
      assert {:ok, claim} = OrganizationDomains.add(owner, "  Acme.Example. ")

      assert claim.domain == "acme.example"
      refute claim.verified_at
      assert OrganizationDomains.record_name(claim) == "_renga-verification.acme.example"
      assert "renga-verification=" <> token = OrganizationDomains.record_value(claim)
      assert byte_size(token) >= 20
      assert [%OrganizationDomain{domain: "acme.example"}] = OrganizationDomains.list(owner)
    end

    test "refuses something that isn't a domain, and a repeat", %{owner: owner} do
      for bad <- ["", "localhost", "acme example", "https://acme.example", "-acme.example"] do
        assert {:error, %Ecto.Changeset{} = changeset} = OrganizationDomains.add(owner, bad)
        assert %{domain: [_]} = errors_on(changeset)
      end

      {:ok, _claim} = OrganizationDomains.add(owner, "acme.example")
      assert {:error, changeset} = OrganizationDomains.add(owner, "ACME.example")
      assert %{domain: ["is already listed"]} = errors_on(changeset)
    end

    test "two organizations may both claim a domain while neither has verified it", %{
      owner: owner
    } do
      other = scope(organization_fixture(), "owner")

      assert {:ok, _claim} = OrganizationDomains.add(owner, "acme.example")
      assert {:ok, _claim} = OrganizationDomains.add(other, "acme.example")
    end

    test "needs an owner", %{organization: organization} do
      admin = scope(organization, "admin")

      assert {:error, :forbidden} = OrganizationDomains.add(admin, "acme.example")
      assert {:error, :forbidden} = OrganizationDomains.add(%Scope{}, "acme.example")
    end
  end

  describe "verify/2" do
    test "verifies when the TXT record holds the token", %{owner: owner} do
      {:ok, claim} = OrganizationDomains.add(owner, "acme.example")
      publish(claim)

      assert {:ok, claim} = OrganizationDomains.verify(owner, claim)
      assert claim.verified_at
      assert claim.checked_at
    end

    test "leaves it unverified when the record is missing or wrong", %{owner: owner} do
      {:ok, claim} = OrganizationDomains.add(owner, "acme.example")

      assert {:error, :record_not_found} = OrganizationDomains.verify(owner, claim)

      FakeTxtResolver.put(OrganizationDomains.record_name(claim), ["renga-verification=other"])
      assert {:error, :record_not_found} = OrganizationDomains.verify(owner, claim)

      FakeTxtResolver.put(OrganizationDomains.record_name(claim), {:error, :timeout})
      assert {:error, :dns_unavailable} = OrganizationDomains.verify(owner, claim)

      refute Repo.reload!(claim).verified_at
    end

    test "only one organization holds a verified domain", %{owner: owner} do
      held = verified(owner, "acme.example")

      other = scope(organization_fixture(), "owner")
      {:ok, claim} = OrganizationDomains.add(other, "acme.example")

      # Both organizations' tokens live at the same name.
      FakeTxtResolver.put(OrganizationDomains.record_name(claim), [
        OrganizationDomains.record_value(held),
        OrganizationDomains.record_value(claim)
      ])

      assert {:error, :verified_elsewhere} = OrganizationDomains.verify(other, claim)
      refute Repo.reload!(claim).verified_at
      assert Repo.reload!(held).verified_at
    end

    test "another organization takes over once the holder's record is gone", %{
      organization: organization,
      owner: owner
    } do
      held = verified(owner, "acme.example")

      other_organization = organization_fixture()
      other = scope(other_organization, "owner")
      {:ok, claim} = OrganizationDomains.add(other, "acme.example")

      # The holder's record is replaced by the newcomer's.
      FakeTxtResolver.put(OrganizationDomains.record_name(claim), [
        OrganizationDomains.record_value(claim)
      ])

      assert {:ok, claim} = OrganizationDomains.verify(other, claim)
      assert claim.verified_at
      refute Repo.reload!(held).verified_at

      assert ["added", "verified", "unverified"] ==
               Enum.map(changes(organization), & &1.metadata["change"])

      assert ["added", "verified"] ==
               Enum.map(changes(other_organization), & &1.metadata["change"])
    end

    test "needs an owner, and the organization's own claim", %{
      organization: organization,
      owner: owner
    } do
      {:ok, claim} = OrganizationDomains.add(owner, "acme.example")
      publish(claim)

      assert {:error, :forbidden} =
               OrganizationDomains.verify(scope(organization, "admin"), claim)

      other = scope(organization_fixture(), "owner")
      assert {:error, :not_found} = OrganizationDomains.verify(other, claim)
      refute Repo.reload!(claim).verified_at
    end
  end

  describe "remove/2" do
    test "removes the claim, verified or not", %{organization: organization, owner: owner} do
      claim = verified(owner, "acme.example")

      assert {:error, :forbidden} =
               OrganizationDomains.remove(scope(organization, "admin"), claim)

      assert {:ok, _claim} = OrganizationDomains.remove(owner, claim)
      assert OrganizationDomains.list(owner) == []
      assert {:error, :not_found} = OrganizationDomains.remove(owner, claim)
    end
  end

  describe "recheck_verified/0" do
    test "unverifies a domain whose record is gone, and keeps one DNS can't answer for", %{
      organization: organization,
      owner: owner
    } do
      kept = verified(owner, "acme.example")
      unanswered = verified(owner, "acme.test")
      gone = verified(owner, "acme.dev")

      FakeTxtResolver.put(OrganizationDomains.record_name(unanswered), {:error, :timeout})
      FakeTxtResolver.put(OrganizationDomains.record_name(gone), {:error, :nxdomain})

      assert :ok = OrganizationDomains.recheck_verified()

      assert Repo.reload!(kept).verified_at
      assert Repo.reload!(unanswered).verified_at
      refute Repo.reload!(gone).verified_at

      unverified = Enum.filter(changes(organization), &(&1.metadata["change"] == "unverified"))
      assert [%ChangeEvent{actor_user_id: nil, field: "acme.dev"} = event] = unverified

      assert ChangeDescription.describe(event) =~
               "acme.dev stopped routing sign-in: its DNS record is gone"
    end

    test "a stale answer doesn't undo a verification made while it was in flight", %{
      organization: organization,
      owner: owner
    } do
      claim = verified(owner, "acme.example")
      reverified_at = DateTime.add(claim.verified_at, 1, :second)

      # While this sweep waits on DNS, another node finds the record gone and
      # the owner restores it and verifies again; then the old answer lands.
      FakeTxtResolver.put(OrganizationDomains.record_name(claim), fn ->
        Repo.update_all(where(OrganizationDomain, id: ^claim.id),
          set: [verified_at: reverified_at]
        )

        {:error, :nxdomain}
      end)

      assert :ok = OrganizationDomains.recheck_verified()

      assert Repo.reload!(claim).verified_at == reverified_at
      refute Enum.any?(changes(organization), &(&1.metadata["change"] == "unverified"))
    end
  end

  test "the worker checks again on its interval" do
    parent = self()

    start_supervised!(
      {OrganizationDomains.Worker, name: nil, interval: 10, sweep: fn -> send(parent, :swept) end}
    )

    assert_receive :swept, 100
    assert_receive :swept, 100
  end

  test "the worker checks as soon as it starts, not a whole interval later" do
    parent = self()

    start_supervised!(
      {OrganizationDomains.Worker,
       name: nil, interval: :timer.hours(24), sweep: fn -> send(parent, :swept) end}
    )

    assert_receive :swept, 1_000
  end

  describe "organization_slug_for_email/1" do
    test "routes an address at a verified domain to an organization with a provider", %{
      organization: organization,
      owner: owner
    } do
      {:ok, claim} = OrganizationDomains.add(owner, "acme.example")
      active_provider(owner)

      refute OrganizationDomains.organization_slug_for_email("sam@acme.example")
      refute OrganizationDomains.any_verified?()

      publish(claim)
      {:ok, _claim} = OrganizationDomains.verify(owner, claim)

      assert OrganizationDomains.any_verified?()

      assert OrganizationDomains.organization_slug_for_email(" Sam@ACME.example ") ==
               organization.slug

      refute OrganizationDomains.organization_slug_for_email("sam@eu.acme.example")
      refute OrganizationDomains.organization_slug_for_email("sam@other.example")
      refute OrganizationDomains.organization_slug_for_email("acme.example")
      refute OrganizationDomains.organization_slug_for_email("a@b@acme.example")
      refute OrganizationDomains.organization_slug_for_email(nil)
    end

    test "routes nobody without a usable provider or once the organization is disabled", %{
      organization: organization,
      owner: owner
    } do
      verified(owner, "acme.example")
      refute OrganizationDomains.organization_slug_for_email("sam@acme.example")

      active_provider(owner)
      assert OrganizationDomains.organization_slug_for_email("sam@acme.example")

      organization |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()
      refute OrganizationDomains.organization_slug_for_email("sam@acme.example")
    end
  end

  test "changes appear in the organization's Activity", %{
    organization: organization,
    owner: owner
  } do
    claim = verified(owner, "acme.example")
    {:ok, _claim} = OrganizationDomains.remove(owner, claim)

    events = changes(organization)
    assert Enum.all?(events, &(&1.actor_user_id == owner.user.id))

    assert [
             "Claimed the email domain acme.example, waiting for its DNS record",
             "Verified the email domain acme.example for sign-in",
             "Removed the email domain acme.example"
           ] == Enum.map(events, &ChangeDescription.describe/1)
  end
end
