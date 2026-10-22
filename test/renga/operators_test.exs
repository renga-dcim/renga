defmodule Renga.OperatorsTest do
  use Renga.DataCase, async: true

  alias Renga.DeploymentAudit
  alias Renga.DeploymentAudit.Event
  alias Renga.Operators

  @peer {203, 0, 113, 7}

  defp context, do: DeploymentAudit.operator("alice")

  defp create_token!(attrs \\ %{}) do
    {:ok, {token, plaintext}} =
      attrs
      |> Enum.into(%{
        name: "control-plane-#{System.unique_integer([:positive])}",
        scopes: ["organizations:read"]
      })
      |> Operators.create_token(context())

    {token, plaintext}
  end

  describe "create_token/2" do
    test "returns the plaintext once and stores only its hash" do
      {token, plaintext} = create_token!()

      assert "renga_operator_" <> secret = plaintext
      assert byte_size(Base.url_decode64!(secret, padding: false)) == 32
      assert token.token_hash == :crypto.hash(:sha256, plaintext)
      refute inspect(token) =~ plaintext
      refute inspect(token) =~ "token_hash"
    end

    test "requires a unique name and known scopes" do
      {token, _plaintext} = create_token!()

      assert {:error, changeset} =
               Operators.create_token(
                 %{name: String.upcase(token.name), scopes: ["usage:read"]},
                 context()
               )

      assert "has already been taken" in errors_on(changeset).name

      assert {:error, changeset} =
               Operators.create_token(%{name: "x", scopes: ["inventory:read"]}, context())

      assert "has an invalid entry" in errors_on(changeset).scopes

      assert {:error, changeset} = Operators.create_token(%{name: "x", scopes: []}, context())
      assert errors_on(changeset).scopes != []
    end

    test "refuses an expiry in the past and malformed sources" do
      past = DateTime.add(DateTime.utc_now(), -60)

      assert {:error, changeset} =
               Operators.create_token(
                 %{name: "x", scopes: ["usage:read"], expires_at: past},
                 context()
               )

      assert "must be in the future" in errors_on(changeset).expires_at

      assert {:error, changeset} =
               Operators.create_token(
                 %{
                   name: "x",
                   scopes: ["usage:read"],
                   allowed_sources: ["10.0.0.1/8"]
                 },
                 context()
               )

      assert errors_on(changeset).allowed_sources != []
    end

    test "records the creation in the deployment audit log without the token" do
      {token, plaintext} = create_token!()

      assert [event] = Repo.all(from event in Event, where: event.target_id == ^token.id)
      assert event.operation == "operator_token.create"
      assert event.outcome == "succeeded"
      assert event.actor == "operator: alice"
      assert event.changed == ~w(name scopes allowed_sources expires_at)
      refute inspect(event) =~ plaintext
      refute inspect(event) =~ Base.encode16(token.token_hash, case: :lower)
    end

    test "records a refused creation and creates nothing" do
      context = context()

      assert {:error, _changeset} =
               Operators.create_token(%{name: "x", scopes: ["inventory:read"]}, context)

      assert [event] =
               Repo.all(from event in Event, where: event.invocation_id == ^context.invocation_id)

      assert {event.outcome, event.reason, event.target_id} == {"rejected", "invalid", nil}
      refute Repo.exists?(from token in Renga.Operators.OperatorToken, where: token.name == "x")
    end
  end

  describe "authenticate/2" do
    test "accepts an active token" do
      {token, plaintext} = create_token!()

      assert {:ok, %{id: id}} = Operators.authenticate(plaintext, @peer)
      assert id == token.id
    end

    test "refuses unknown, revoked, and expired tokens alike" do
      {_token, plaintext} = create_token!()
      assert :error = Operators.authenticate(plaintext <> "x", @peer)
      assert :error = Operators.authenticate("renga_intake_" <> plaintext, @peer)
      assert :error = Operators.authenticate(nil, @peer)

      {revoked, revoked_plaintext} = create_token!()
      {:ok, _revoked} = Operators.revoke_token(revoked, context())
      assert :error = Operators.authenticate(revoked_plaintext, @peer)

      {expiring, expiring_plaintext} =
        create_token!(%{expires_at: DateTime.add(DateTime.utc_now(), 60)})

      Repo.update_all(
        from(token in Renga.Operators.OperatorToken, where: token.id == ^expiring.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert :error = Operators.authenticate(expiring_plaintext, @peer)
    end

    test "honours source address lists, including IPv4-mapped peers" do
      {_token, plaintext} =
        create_token!(%{allowed_sources: ["203.0.113.0/24", "2001:db8::/32"]})

      assert {:ok, _token} = Operators.authenticate(plaintext, @peer)
      assert {:ok, _token} = Operators.authenticate(plaintext, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})

      assert {:ok, _token} =
               Operators.authenticate(plaintext, {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107})

      assert :error = Operators.authenticate(plaintext, {198, 51, 100, 1})
    end
  end

  describe "revoke_token/2" do
    test "keeps the first revocation time and audits both attempts" do
      {token, _plaintext} = create_token!()

      {:ok, revoked} = Operators.revoke_token(token, context())
      {:ok, again} = Operators.revoke_token(token, context())

      assert revoked.revoked_at
      assert again.revoked_at == revoked.revoked_at

      changes =
        Repo.all(
          from event in Event,
            where: event.target_id == ^token.id and event.operation == "operator_token.revoke",
            order_by: event.inserted_at,
            select: {event.outcome, event.changed}
        )

      assert Enum.sort(changes) == [{"succeeded", []}, {"succeeded", ["revoked_at"]}]
    end
  end

  describe "enabled?/0" do
    test "is true only while some token can authenticate" do
      Repo.delete_all(Renga.Operators.OperatorToken)
      refute Operators.enabled?()

      {token, _plaintext} = create_token!()
      assert Operators.enabled?()

      {:ok, _token} = Operators.revoke_token(token, context())
      refute Operators.enabled?()
    end
  end

  describe "get_token/1" do
    test "finds a token by ID or name" do
      {token, _plaintext} = create_token!()

      assert Operators.get_token(token.id).id == token.id
      assert Operators.get_token(token.name).id == token.id
      assert Operators.get_token("missing") == nil
    end
  end
end
