defmodule Renga.Release.ProvidersTest do
  # Reads RENGA_CLIENT_SECRET and changes the sign-in settings.
  use Renga.DataCase, async: false

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.SignInPolicy
  alias Renga.Release.Providers

  setup do
    System.put_env("RENGA_CLIENT_SECRET", "from-the-environment")

    on_exit(fn ->
      System.delete_env("RENGA_CLIENT_SECRET")
      Application.delete_env(:renga, :local_sign_in)
    end)
  end

  defp add(id) do
    Providers.run(
      ~w(add --actor jane --id #{id} --issuer https://sso.example.com --name SSO --client-id renga) ++
        ~w(--scopes groups --email-domains example.com)
    )
  end

  test "adds a pending provider with the secret from the environment" do
    assert {:ok, output} = add("sso")
    assert output =~ "pending"

    provider = IdentityProviders.get("sso")
    revision = IdentityProviders.pending_revision(provider)
    assert revision.scopes == ["groups"]
    assert revision.email_domains == ["example.com"]
    assert {:ok, "from-the-environment"} = IdentityProviders.client_secret(revision)

    assert [%{actor: "operator: jane"}] = IdentityProviders.list_events(provider)
  end

  test "test prints a single-use link for the pending revision" do
    {:ok, _} = add("sso")
    assert {:ok, output} = Providers.run(~w(test sso --actor jane))
    assert output =~ ~r{\nhttp://localhost:4002/users/providers/test/[A-Za-z0-9_-]+$}
    assert output =~ "revision 1"
  end

  test "update writes a new pending revision and changes display fields in place" do
    {:ok, _} = add("sso")
    System.delete_env("RENGA_CLIENT_SECRET")

    assert {:ok, output} =
             Providers.run(
               ~w(update sso --actor jane --client-id renga-2 --name Company --hidden)
             )

    assert output =~ "Revision 2"
    provider = IdentityProviders.get("sso")
    assert provider.display_name == "Company"
    assert provider.hidden
    assert IdentityProviders.pending_revision(provider).client_id == "renga-2"
  end

  test "list, enable, and disable" do
    {:ok, _} = add("sso")

    assert {:ok, list} = Providers.run(["list"])
    assert list =~ "local sign-in: enabled"
    assert list =~ "sso\toidc\tSSO\tenabled\tactive -\tpending 1"

    assert {:ok, "sso is disabled."} = Providers.run(~w(disable sso --actor jane))
    assert {:ok, "sso is enabled."} = Providers.run(~w(enable sso --actor jane))
  end

  test "recover-local turns local sign-in on and off" do
    Application.put_env(:renga, :local_sign_in, :disabled)

    assert {:ok, output} = Providers.run(~w(recover-local --actor jane --minutes 30))
    assert output =~ "Local sign-in is on until"
    assert SignInPolicy.local_sign_in?()

    assert {:ok, output} = Providers.run(~w(recover-local --actor jane --revoke))
    assert output =~ "Revoked 1"
    refute SignInPolicy.local_sign_in?()

    assert {:error, _} = Providers.run(~w(recover-local --actor jane --minutes 5000))
  end

  test "explains mistakes" do
    assert {:error, message} = Providers.run(~w(add --id sso))
    assert message =~ "--actor"

    assert {:error, message} =
             Providers.run(
               ~w(add --actor jane --id BAD! --issuer http://x --name X --client-id y)
             )

    assert message =~ "id:"
    assert message =~ "issuer:"

    assert {:error, "No provider has that ID."} = Providers.run(~w(enable nope --actor jane))
    assert {:error, usage} = Providers.run(["nonsense"])
    assert usage =~ "bin/providers list"
  end
end
