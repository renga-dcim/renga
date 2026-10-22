defmodule Renga.Accounts.ProviderMFATest do
  use Renga.DataCase, async: true

  import Renga.InventoryFixtures

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.ProviderMFA
  alias Renga.Accounts.SessionMFA

  @operator {:operator, "release"}

  defp deployment_provider(attrs \\ %{}) do
    {:ok, {provider, _revision}} =
      IdentityProviders.create(
        Map.merge(
          %{
            "id" => "sso-#{System.unique_integer([:positive])}",
            "kind" => "oidc",
            "issuer" => "https://sso.example.com/",
            "display_name" => "SSO",
            "client_id" => "renga",
            "client_secret" => "s3cret"
          },
          attrs
        ),
        @operator
      )

    provider
  end

  # Organization providers have no store of their own yet, so these rows
  # stand in for one.
  defp organization_provider(organization, attrs) do
    Repo.insert!(
      struct!(
        %IdentityProvider{
          id: "org-#{System.unique_integer([:positive])}",
          kind: "oidc",
          issuer: "https://idp.example.com/",
          display_name: "Company",
          organization_id: organization.id
        },
        attrs
      )
    )
  end

  defp mark(provider, combinations \\ []) do
    {:ok, provider} =
      IdentityProviders.set_mfa_mark(
        provider,
        %{"enforces_mfa" => true, "mfa_amr_combinations" => combinations},
        @operator
      )

    provider
  end

  defp signed_in_through(provider, claims \\ %{}), do: SessionMFA.for_provider(provider, claims)

  setup do
    %{organization: organization_fixture(), other: organization_fixture()}
  end

  test "Renga's own second factor satisfies any organization", %{organization: organization} do
    assert ProviderMFA.satisfies?(SessionMFA.for_method("passkey"), organization.id)
    refute ProviderMFA.satisfies?(SessionMFA.for_method("password"), organization.id)
    refute ProviderMFA.satisfies?(nil, organization.id)
  end

  describe "deployment providers" do
    test "count only while marked", %{organization: organization} do
      provider = deployment_provider()
      evidence = signed_in_through(provider)
      refute ProviderMFA.satisfies?(evidence, organization.id)

      provider = mark(provider)
      assert ProviderMFA.satisfies?(evidence, organization.id)

      {:ok, _provider} =
        IdentityProviders.set_mfa_mark(provider, %{"enforces_mfa" => false}, @operator)

      refute ProviderMFA.satisfies?(evidence, organization.id)
    end

    test "count across organizations", %{organization: organization, other: other} do
      evidence = deployment_provider() |> mark() |> signed_in_through()

      assert ProviderMFA.satisfies?(evidence, organization.id)
      assert ProviderMFA.satisfies?(evidence, other.id)
    end

    test "stop counting once removed", %{organization: organization} do
      provider = mark(deployment_provider())
      {:ok, _} = IdentityProviders.remove(provider, @operator)

      refute ProviderMFA.satisfies?(signed_in_through(provider), organization.id)
    end
  end

  describe "organization providers" do
    test "a mark counts only for the owning organization, with and without amr", %{
      organization: organization,
      other: other
    } do
      provider = organization_provider(organization, %{enforces_mfa: true})

      for claims <- [%{}, %{"amr" => ["mfa"]}] do
        evidence = signed_in_through(provider, claims)
        assert ProviderMFA.satisfies?(evidence, organization.id)
        refute ProviderMFA.satisfies?(evidence, other.id)
      end
    end

    test "evidence naming another owner than the provider's counts nowhere", %{
      organization: organization,
      other: other
    } do
      provider = organization_provider(organization, %{enforces_mfa: true})
      evidence = %{signed_in_through(provider) | provider_organization_id: other.id}

      refute ProviderMFA.satisfies?(evidence, organization.id)
      refute ProviderMFA.satisfies?(evidence, other.id)
    end
  end

  describe "amr" do
    setup do
      %{provider: mark(deployment_provider(), ["otp+pwd"])}
    end

    test "absent, the mark decides", %{provider: provider, organization: organization} do
      assert ProviderMFA.satisfies?(signed_in_through(provider), organization.id)
    end

    test "mfa or an approved combination counts", %{
      provider: provider,
      organization: organization
    } do
      for amr <- [["mfa"], ["pwd", "otp"], ["otp", "pwd", "geo"]] do
        assert ProviderMFA.satisfies?(
                 signed_in_through(provider, %{"amr" => amr}),
                 organization.id
               ),
               "expected #{inspect(amr)} to count"
      end
    end

    test "any other amr asks for Renga's second step", %{
      provider: provider,
      organization: organization
    } do
      for amr <- [["pwd"], ["pwd", "kba"], ["otp"], [], "mfa"] do
        refute ProviderMFA.satisfies?(
                 signed_in_through(provider, %{"amr" => amr}),
                 organization.id
               ),
               "expected #{inspect(amr)} not to count"
      end
    end
  end

  describe "normalize_combination/1" do
    test "sorts the methods of a combination of independent factors" do
      assert {:ok, "otp+pwd"} = ProviderMFA.normalize_combination("pwd + OTP")
      assert {:ok, "face+hwk"} = ProviderMFA.normalize_combination("hwk+face")
      assert {:ok, "pin+sc+user"} = ProviderMFA.normalize_combination("sc+pin+user")
    end

    test "refuses methods of one factor, however many" do
      assert {:error, message} = ProviderMFA.normalize_combination("pwd+kba")
      assert message =~ "two independent factors"
      assert {:error, _} = ProviderMFA.normalize_combination("otp+sms+hwk")
      assert {:error, _} = ProviderMFA.normalize_combination("pwd+geo")
    end

    test "refuses methods RFC 8176 does not register" do
      assert {:error, message} = ProviderMFA.normalize_combination("pwd+ngcmfa")
      assert message =~ "ngcmfa is not an RFC 8176 method"
    end
  end
end
