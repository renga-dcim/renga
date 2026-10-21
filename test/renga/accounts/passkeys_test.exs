defmodule Renga.Accounts.PasskeysTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures

  alias Renga.Accounts.Passkeys
  alias Renga.FakeAuthenticator

  defp register(user, authenticator \\ FakeAuthenticator.new()) do
    response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))
    {:ok, passkey} = Passkeys.register(user, response, "Laptop")
    {authenticator, passkey}
  end

  describe "register/3" do
    test "stores a passkey with its name and flags" do
      user = user_fixture()
      {authenticator, passkey} = register(user)

      assert passkey.name == "Laptop"
      assert passkey.credential_id == authenticator.credential_id
      assert passkey.transports == ["internal"]
      assert [%{id: id}] = Passkeys.list(user)
      assert id == passkey.id
      assert Passkeys.any?(user)
    end

    test "requires user verification" do
      user = user_fixture()
      authenticator = FakeAuthenticator.new(user_verified: false)
      response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))

      assert {:error, :invalid_response} = Passkeys.register(user, response)
      refute Passkeys.any?(user)
    end

    test "rejects another origin" do
      user = user_fixture()

      response =
        FakeAuthenticator.register(
          FakeAuthenticator.new(),
          Passkeys.registration_options(user),
          "https://evil.example"
        )

      assert {:error, :invalid_response} = Passkeys.register(user, response)
    end

    test "a challenge works once, and only for the user it was issued to" do
      user = user_fixture()
      options = Passkeys.registration_options(user)
      response = FakeAuthenticator.register(FakeAuthenticator.new(), options)

      assert {:error, :invalid_challenge} = Passkeys.register(user_fixture(), response)
      assert {:error, :invalid_challenge} = Passkeys.register(user, response)

      options = Passkeys.registration_options(user)
      response = FakeAuthenticator.register(FakeAuthenticator.new(), options)
      assert {:ok, _passkey} = Passkeys.register(user, response)
      assert {:error, :invalid_challenge} = Passkeys.register(user, response)
    end

    test "refuses a response without a credential or from another site's frame" do
      user = user_fixture()

      for authenticator <- [
            FakeAuthenticator.new(attested: false),
            FakeAuthenticator.new(client_data: %{"crossOrigin" => true}),
            FakeAuthenticator.new(client_data: %{"type" => "webauthn.get"})
          ] do
        response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))
        assert {:error, _} = Passkeys.register(user, response)
      end

      refute Passkeys.any?(user)
    end

    test "refuses a key algorithm Renga did not offer" do
      user = user_fixture()

      for alg <- [-8, nil] do
        authenticator = FakeAuthenticator.new(alg: alg)
        response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(user))
        assert {:error, :invalid_response} = Passkeys.register(user, response)
      end

      refute Passkeys.any?(user)
    end

    test "a credential belongs to one account" do
      authenticator = FakeAuthenticator.new()
      register(user_fixture(), authenticator)
      other = user_fixture()

      response = FakeAuthenticator.register(authenticator, Passkeys.registration_options(other))
      assert {:error, :already_registered} = Passkeys.register(other, response)
    end
  end

  describe "authenticate/3" do
    setup do
      user = user_fixture()
      {authenticator, passkey} = register(user)
      %{user: user, authenticator: authenticator, passkey: passkey}
    end

    test "a discoverable passkey signs its owner in", %{user: user, authenticator: authenticator} do
      response =
        FakeAuthenticator.assert(authenticator, Passkeys.authentication_options("sign_in"))

      assert {:ok, signed_in, passkey} = Passkeys.authenticate("sign_in", response)
      assert signed_in.id == user.id
      assert passkey.last_used_at
    end

    test "a response is accepted once", %{authenticator: authenticator} do
      response =
        FakeAuthenticator.assert(authenticator, Passkeys.authentication_options("sign_in"))

      assert {:ok, _user, _passkey} = Passkeys.authenticate("sign_in", response)
      assert {:error, :invalid_challenge} = Passkeys.authenticate("sign_in", response)
    end

    test "a challenge for one purpose cannot complete another", %{
      user: user,
      authenticator: authenticator
    } do
      options = Passkeys.authentication_options("second_step", user)
      response = FakeAuthenticator.assert(authenticator, options)

      assert {:error, :invalid_challenge} = Passkeys.authenticate("sign_in", response)
    end

    test "with a user, only that user's passkeys count", %{authenticator: authenticator} do
      other = user_fixture()
      options = Passkeys.authentication_options("recheck", other)
      response = FakeAuthenticator.assert(authenticator, options)

      assert {:error, _reason} = Passkeys.authenticate("recheck", response, other)
    end

    test "a forged signature fails", %{authenticator: authenticator} do
      response =
        FakeAuthenticator.assert(authenticator, Passkeys.authentication_options("sign_in"))

      forged = %{response | "signature" => Base.url_encode64("nope", padding: false)}

      assert {:error, _reason} = Passkeys.authenticate("sign_in", forged)
    end

    test "requires user verification", %{authenticator: authenticator} do
      authenticator = %{authenticator | user_verified: false}

      response =
        FakeAuthenticator.assert(authenticator, Passkeys.authentication_options("sign_in"))

      assert {:error, _reason} = Passkeys.authenticate("sign_in", response)
    end

    test "a discoverable sign-in needs the owner's user handle", %{
      user: user,
      authenticator: authenticator
    } do
      other = user_fixture()
      other_handle = Base.url_encode64(Ecto.UUID.dump!(other.id), padding: false)

      for handle <- [:omit, other_handle, "not base64!"] do
        response =
          FakeAuthenticator.assert(
            %{authenticator | user_handle: handle},
            Passkeys.authentication_options("sign_in")
          )

        assert {:error, _} = Passkeys.authenticate("sign_in", response)
      end

      # With the user already known, the handle may be absent but not wrong.
      response =
        FakeAuthenticator.assert(
          %{authenticator | user_handle: :omit},
          Passkeys.authentication_options("second_step", user)
        )

      assert {:ok, _user, _passkey} = Passkeys.authenticate("second_step", response, user)

      response =
        FakeAuthenticator.assert(
          %{authenticator | user_handle: other_handle},
          Passkeys.authentication_options("second_step", user)
        )

      assert {:error, _} = Passkeys.authenticate("second_step", response, user)
    end

    test "malformed client data is refused, not raised", %{authenticator: authenticator} do
      response =
        FakeAuthenticator.assert(authenticator, Passkeys.authentication_options("sign_in"))

      for client_data <- [%{"challenge" => 42}, %{"type" => "other", "challenge" => "x"}] do
        response = %{response | "clientDataJSON" => encode(Jason.encode!(client_data))}
        assert {:error, _} = Passkeys.authenticate("sign_in", response)
      end

      # Signed over a live challenge, so only these fields are wrong.
      for client_data <- [%{"type" => "webauthn.create"}, %{"crossOrigin" => true}] do
        response =
          FakeAuthenticator.assert(
            %{authenticator | client_data: client_data},
            Passkeys.authentication_options("sign_in")
          )

        assert {:error, _} = Passkeys.authenticate("sign_in", response)
      end

      response =
        FakeAuthenticator.assert(
          %{authenticator | client_data: %{"crossOrigin" => false}},
          Passkeys.authentication_options("sign_in")
        )

      assert {:ok, _user, _passkey} = Passkeys.authenticate("sign_in", response)
    end

    test "rejects a counter that went backwards" do
      user = user_fixture()
      {authenticator, _passkey} = register(user, FakeAuthenticator.new(sign_count: 5))

      ok = %{authenticator | sign_count: 6}
      response = FakeAuthenticator.assert(ok, Passkeys.authentication_options("sign_in"))
      assert {:ok, _user, _passkey} = Passkeys.authenticate("sign_in", response)

      cloned = %{authenticator | sign_count: 6}
      response = FakeAuthenticator.assert(cloned, Passkeys.authentication_options("sign_in"))
      assert {:error, :sign_count} = Passkeys.authenticate("sign_in", response)
    end

    test "rejects a counter that fell back to zero" do
      user = user_fixture()
      {authenticator, _passkey} = register(user, FakeAuthenticator.new(sign_count: 5))

      reset = %{authenticator | sign_count: 0}
      response = FakeAuthenticator.assert(reset, Passkeys.authentication_options("sign_in"))
      assert {:error, :sign_count} = Passkeys.authenticate("sign_in", response)
    end

    test "a removed passkey no longer signs in", %{
      user: user,
      authenticator: authenticator,
      passkey: passkey
    } do
      {:ok, _passkey} = Passkeys.delete(user, passkey.id)

      response =
        FakeAuthenticator.assert(authenticator, Passkeys.authentication_options("sign_in"))

      assert {:error, _reason} = Passkeys.authenticate("sign_in", response)
    end
  end

  defp encode(bytes), do: Base.url_encode64(bytes, padding: false)
end
