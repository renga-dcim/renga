defmodule RengaWeb.Operator.OrganizationControllerTest do
  use RengaWeb.OperatorCase, async: true

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationInvitation
  alias Renga.DeploymentAudit.Event
  alias Renga.Inventory
  alias Renga.Members
  alias Renga.Operators
  alias Renga.Repo

  setup %{conn: conn} do
    {token, plaintext} = operator_token_fixture(%{name: "cloud"})
    %{conn: authorize(conn, plaintext), token: token}
  end

  defp write(conn, path, body, key) do
    conn
    |> put_req_header("content-type", "application/json")
    |> then(&if(key, do: put_req_header(&1, "idempotency-key", key), else: &1))
    |> post(path, Jason.encode!(body))
  end

  defp events(operation) do
    Event
    |> where(operation: ^operation)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
    |> Enum.map(&{&1.outcome, &1.reason})
  end

  defp token_from_email do
    assert_received {:email, %{subject: "You're invited" <> _, text_body: body}}
    [_, url] = Regex.run(~r{(\S+/invitations/\S+)}, body)
    url
  end

  describe "POST /operator/v1/organizations" do
    test "creates an organization with no members", %{conn: conn, token: token} do
      conn = write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "acme"}, "k1")

      assert %{"id" => id, "name" => "Acme", "slug" => "acme", "status" => "active"} =
               body = valid_operator_response(conn, 201)

      assert body["members"] == []
      assert %Organization{name: "Acme"} = Repo.get!(Organization, id)

      assert [%Event{outcome: "succeeded", actor: "token: cloud"} = event] =
               Repo.all(where(Event, operation: "organization.create"))

      assert event.actor_token_id == token.id
      assert event.organization_id == id

      scope = Renga.Accounts.scope_for(Repo.get!(Organization, id))

      assert [%{kind: "organization_created", metadata: %{"operator" => "token: cloud"}}] =
               Inventory.list_activity(scope)
    end

    test "returns the same organization for a retry with the same key", %{conn: conn} do
      first = write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "acme"}, "k1")
      body = valid_operator_response(first, 201)

      retry = write(conn, "/operator/v1/organizations", %{slug: "acme", name: "Acme"}, "k1")
      assert valid_operator_response(retry, 201) == body
      assert get_resp_header(retry, "idempotent-replayed") == ["true"]

      assert Repo.aggregate(where(Organization, slug: "acme"), :count) == 1
      assert events("organization.create") == [{"succeeded", nil}]
    end

    test "refuses a different request under a used key", %{conn: conn} do
      write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "acme"}, "k1")
      conn = write(conn, "/operator/v1/organizations", %{name: "Other", slug: "other"}, "k1")

      assert valid_operator_response(conn, 409) == %{"error" => "idempotency_key_reused"}
      refute Repo.get_by(Organization, slug: "other")

      assert events("organization.create") ==
               [{"succeeded", nil}, {"rejected", "idempotency_key_reused"}]
    end

    test "keeps keys apart per token", %{conn: conn} do
      write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "acme"}, "k1")
      {_token, other} = operator_token_fixture()

      conn =
        conn
        |> authorize(other)
        |> write("/operator/v1/organizations", %{name: "Other", slug: "other"}, "k1")

      assert valid_operator_response(conn, 201)["slug"] == "other"
    end

    test "requires an idempotency key", %{conn: conn} do
      conn = write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "acme"}, nil)

      assert valid_operator_response(conn, 400) == %{"error" => "idempotency_key_required"}
      assert events("organization.create") == [{"rejected", "idempotency_key_required"}]
    end

    test "refuses a malformed body and records the attempt", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("idempotency-key", "k1")
        |> post("/operator/v1/organizations", "{not json")

      assert valid_operator_response(conn, 400) == %{"error" => "malformed_body"}
      assert events("organization.create") == [{"rejected", "malformed_body"}]
    end

    test "refuses an invalid or taken slug", %{conn: conn} do
      organization_fixture(%{slug: "taken"})

      conn1 = write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "Not ok"}, "k1")

      assert %{"error" => "invalid", "errors" => %{"slug" => [_]}} =
               valid_operator_response(conn1, 422)

      conn2 = write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "taken"}, "k2")

      assert valid_operator_response(conn2, 422) ==
               %{"error" => "invalid", "errors" => %{"slug" => ["has already been taken"]}}

      # A refused request stores nothing, so the key can be used again.
      conn3 = write(conn, "/operator/v1/organizations", %{name: "Acme", slug: "acme"}, "k2")
      assert valid_operator_response(conn3, 201)

      assert events("organization.create") ==
               [{"rejected", "invalid"}, {"rejected", "invalid"}, {"succeeded", nil}]
    end

    test "needs organizations:write", %{conn: conn} do
      {_token, reader} = operator_token_fixture(%{scopes: ["organizations:read"]})

      conn =
        conn
        |> authorize(reader)
        |> write("/operator/v1/organizations", %{name: "Acme", slug: "acme"}, "k1")

      assert valid_operator_response(conn, 403) == %{"error" => "forbidden"}
      assert events("organization.create") == [{"rejected", "forbidden"}]
    end
  end

  describe "GET /operator/v1/organizations/:id" do
    test "reads an organization and its active members", %{conn: conn} do
      organization = organization_fixture()
      owner = user_fixture()

      {:ok, _} =
        Renga.Accounts.create_organization_membership(organization, %{
          user_id: owner.id,
          role: "owner"
        })

      conn = get(conn, "/operator/v1/organizations/#{organization.id}")

      assert valid_operator_response(conn, 200) == %{
               "id" => organization.id,
               "name" => organization.name,
               "slug" => organization.slug,
               "status" => "active",
               "members" => [%{"email" => owner.email, "role" => "owner"}]
             }
    end

    test "answers 404 for an unknown or malformed id", %{conn: conn} do
      for id <- [Ecto.UUID.generate(), "nope"] do
        assert get(conn, "/operator/v1/organizations/#{id}") |> json_response(404) ==
                 %{"error" => "not_found"}
      end
    end

    test "needs organizations:read, which organizations:write includes", %{conn: conn} do
      organization = organization_fixture()

      for {scopes, status} <- [
            {["usage:read"], 403},
            {["organizations:read"], 200},
            {["organizations:write"], 200}
          ] do
        {_token, plaintext} = operator_token_fixture(%{scopes: scopes})

        conn =
          conn |> authorize(plaintext) |> get("/operator/v1/organizations/#{organization.id}")

        assert valid_operator_response(conn, status)
      end
    end
  end

  describe "POST /operator/v1/organizations/:id/owner-invitations" do
    setup do
      %{organization: organization_fixture(%{name: "Acme"})}
    end

    defp invite(conn, organization, email, key \\ "i1") do
      write(
        conn,
        "/operator/v1/organizations/#{organization.id}/owner-invitations",
        %{email: email},
        key
      )
    end

    test "emails an owner invitation that the confirmed address can accept",
         %{conn: conn, organization: organization} do
      user = user_fixture()
      conn = invite(conn, organization, user.email)

      body = valid_operator_response(conn, 201)
      assert %{"email" => email, "role" => "owner", "organization_id" => org_id} = body
      assert {email, org_id} == {user.email, organization.id}
      refute Jason.encode!(body) =~ "invitations/"

      url = token_from_email()
      assert url =~ RengaWeb.Endpoint.url()
      [_, token] = Regex.run(~r{/invitations/(\S+)}, url)

      assert {:error, :wrong_email} = Members.accept_invitation(user_fixture(), token)
      assert {:ok, membership} = Members.accept_invitation(user, token)
      assert membership.role == "owner"

      kinds =
        organization
        |> Renga.Accounts.scope_for()
        |> Inventory.list_activity()
        |> Enum.map(& &1.kind)

      assert kinds == ["member_joined", "member_invited"]

      assert [{"succeeded", nil}] = events("organization.invite_owner")
    end

    test "names the operator on the invitation", %{
      conn: conn,
      organization: organization,
      token: token
    } do
      invite(conn, organization, "owner@acme.test")

      invitation = Repo.get_by!(OrganizationInvitation, email: "owner@acme.test")
      assert invitation.invited_by_operator == "token: cloud"
      assert invitation.invited_by_operator_token_id == token.id
      assert invitation.invited_by_user_id == nil
    end

    test "stops working when the token that made it is revoked",
         %{conn: conn, organization: organization, token: token} do
      user = user_fixture()
      invite(conn, organization, user.email)
      [_, invitation_token] = Regex.run(~r{/invitations/(\S+)}, token_from_email())

      {:ok, _} = Operators.revoke_token(token, Renga.DeploymentAudit.operator("test"))
      assert {:error, :forbidden} = Members.accept_invitation(user, invitation_token)
    end

    test "a retry returns the same invitation and sends no second email",
         %{conn: conn, organization: organization} do
      first = invite(conn, organization, "owner@acme.test")
      body = valid_operator_response(first, 201)
      token_from_email()

      retry = invite(conn, organization, "owner@acme.test")
      assert valid_operator_response(retry, 201) == body
      refute_received {:email, _}
    end

    test "a new key replaces the open invitation for the address",
         %{conn: conn, organization: organization} do
      invite(conn, organization, "owner@acme.test", "i1")
      invite(conn, organization, "owner@acme.test", "i2")

      open =
        OrganizationInvitation
        |> where(email: "owner@acme.test")
        |> where([i], is_nil(i.revoked_at))
        |> Repo.all()

      assert length(open) == 1
    end

    test "the same key for another organization is a conflict",
         %{conn: conn, organization: organization} do
      invite(conn, organization, "owner@acme.test")
      conn = invite(conn, organization_fixture(), "owner@acme.test")
      assert valid_operator_response(conn, 409) == %{"error" => "idempotency_key_reused"}
    end

    test "refuses an address that already belongs to a member",
         %{conn: conn, organization: organization} do
      user = user_fixture()

      {:ok, _} =
        Renga.Accounts.create_organization_membership(organization, %{
          user_id: user.id,
          role: "viewer"
        })

      conn = invite(conn, organization, user.email)

      assert valid_operator_response(conn, 422) ==
               %{"error" => "invalid", "errors" => %{"email" => ["already belongs to a member"]}}
    end

    test "answers 404 for an unknown or disabled organization", %{
      conn: conn,
      organization: organization
    } do
      conn1 =
        write(
          conn,
          "/operator/v1/organizations/#{Ecto.UUID.generate()}/owner-invitations",
          %{email: "a@b.test"},
          "i1"
        )

      assert valid_operator_response(conn1, 404) == %{"error" => "not_found"}

      {:ok, _} = Renga.Accounts.update_organization(organization, %{status: "disabled"})
      conn2 = invite(conn, organization, "a@b.test", "i2")
      assert valid_operator_response(conn2, 404) == %{"error" => "not_found"}

      assert [{"rejected", "not_found"}, {"rejected", "not_found"}] =
               events("organization.invite_owner")
    end
  end
end
