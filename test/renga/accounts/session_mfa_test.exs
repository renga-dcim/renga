defmodule Renga.Accounts.SessionMFATest do
  use ExUnit.Case, async: true

  alias Renga.Accounts.SessionMFA

  describe "for_method/1" do
    test "a passkey and the second step are Renga's own second factor" do
      for method <- ["passkey", :passkey, :totp, :recovery_code] do
        assert SessionMFA.second_factor?(SessionMFA.for_method(method))
      end
    end

    test "a password or emailed link alone is not" do
      for method <- ["password", "magic_link", nil] do
        refute SessionMFA.second_factor?(SessionMFA.for_method(method))
      end
    end
  end

  describe "for_provider/2" do
    @provider %{id: "sso", organization_id: nil}

    test "keeps the provider, its owner, and the amr claim" do
      owned = %{id: "acme", organization_id: Ecto.UUID.generate()}

      assert %SessionMFA{
               second_factor_at: nil,
               provider_id: "acme",
               provider_organization_id: organization_id,
               provider_amr: ["pwd", "otp"]
             } = SessionMFA.for_provider(owned, %{"amr" => ["pwd", "otp"]})

      assert organization_id == owned.organization_id
    end

    test "a token without amr leaves it absent" do
      assert %SessionMFA{provider_amr: nil} = SessionMFA.for_provider(@provider, %{})
      assert %SessionMFA{provider_amr: nil} = SessionMFA.for_provider(@provider, %{"amr" => nil})
    end

    # A malformed claim is present, so it must not fall back to the mark
    # alone deciding; an empty list proves no factor.
    test "a malformed amr proves nothing rather than being ignored" do
      for amr <- ["mfa", [1, 2], %{"mfa" => true}, ["mfa", 1]] do
        assert %SessionMFA{provider_amr: []} =
                 SessionMFA.for_provider(@provider, %{"amr" => amr})
      end
    end
  end
end
