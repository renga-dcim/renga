defmodule Renga.EnrollmentTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Enrollment
  alias Renga.Enrollment.EnrollmentPolicy

  setup do
    user = user_fixture()
    organization = organization_fixture()
    membership = organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)
    %{user: user, organization: organization, membership: membership, scope: scope}
  end

  test "versions are allocated and tenant-scoped", %{scope: scope} do
    assert {:ok, first} =
             Enrollment.create_policy(scope, %{
               name: "default",
               document: %{"effect" => "deny"}
             })

    assert {:ok, second} =
             Enrollment.create_policy(scope, %{
               name: "default",
               document: %{"effect" => "allow"}
             })

    assert {:ok, independent} =
             Enrollment.create_policy(scope, %{"name" => "restricted", "document" => %{}})

    assert {first.version, second.version} == {1, 2}
    assert independent.version == 1

    assert Enum.map(Enrollment.list_policies(scope), & &1.id) == [
             second.id,
             first.id,
             independent.id
           ]

    other_user = user_fixture()
    other_org = organization_fixture()
    organization_membership_fixture(other_user, other_org, %{role: "owner"})
    other_scope = Accounts.scope_for_user(other_user, other_org.id)
    assert Enrollment.list_policies(other_scope) == []
    assert_raise Ecto.NoResultsError, fn -> Enrollment.get_policy!(other_scope, first.id) end
  end

  test "profile composite foreign keys reject cross-tenant versions", %{scope: scope} do
    {:ok, policy} = Enrollment.create_policy(scope, %{name: "default", document: %{}})

    {:ok, verifier} =
      Enrollment.create_verifier_configuration(scope, %{
        name: "workload",
        kind: "manual",
        subject_cardinality: "group",
        configuration: %{}
      })

    other_user = user_fixture()
    other_org = organization_fixture()
    organization_membership_fixture(other_user, other_org, %{role: "owner"})
    other_scope = Accounts.scope_for_user(other_user, other_org.id)

    {:ok, foreign_policy} =
      Enrollment.create_policy(other_scope, %{name: "default", document: %{}})

    assert {:error, changeset} =
             Enrollment.create_profile(scope, %{
               selector: "prod",
               name: "Production",
               enrollment_policy_id: foreign_policy.id,
               verifier_configuration_id: verifier.id
             })

    assert "does not exist" in errors_on(changeset).enrollment_policy_id
    assert policy.organization_id == scope.organization_id
  end

  test "mutations recheck cached administrator authorization", %{
    scope: scope,
    membership: membership
  } do
    {:ok, _} = Accounts.update_organization_membership(membership, %{role: "viewer"})

    assert {:error, :forbidden} =
             Enrollment.create_policy(scope, %{name: "default", document: %{}})
  end

  test "policy rows are immutable in the database", %{scope: scope} do
    {:ok, policy} = Enrollment.create_policy(scope, %{name: "default", document: %{}})

    assert_raise Postgrex.Error, fn ->
      policy |> EnrollmentPolicy.changeset(%{document: %{"changed" => true}}) |> Repo.update!()
    end
  end

  test "safe changesets do not cast organization or cryptographic material", %{scope: scope} do
    {:ok, policy} =
      Enrollment.create_policy(scope, %{
        organization_id: Ecto.UUID.generate(),
        version: 99,
        name: "default",
        document: %{}
      })

    assert policy.organization_id == scope.organization_id
    assert policy.version == 1
  end

  test "OIDC profile setup atomically creates scoped, fail-closed records", %{scope: scope} do
    assert {:ok, profile} = Enrollment.create_oidc_profile(scope, oidc_profile_attrs())
    assert profile.selector == "production"

    [policy] = Enrollment.list_policies(scope)
    [verifier] = Enrollment.list_verifier_configurations(scope)
    assert policy.document["rule"]["attribute"] == ["verified", "claims", "role"]
    assert policy.document["rule"]["value"] == "installer"

    assert verifier.configuration["required_claims"] == [
             %{"path" => ["role"], "type" => "string"}
           ]

    assert verifier.configuration["http_timeout_ms"] == 2_000
    assert verifier.configuration["max_jwks_staleness_seconds"] == 3_600

    other_user = user_fixture()
    other_org = organization_fixture()
    organization_membership_fixture(other_user, other_org, %{role: "owner"})
    other_scope = Accounts.scope_for_user(other_user, other_org.id)
    assert Enrollment.list_profiles(other_scope) == []
  end

  test "invalid OIDC profile setup leaves no partial versions", %{scope: scope} do
    attrs = Map.put(oidc_profile_attrs(), :jwks_url, "http://insecure.example/jwks")
    assert {:error, %Ecto.Changeset{}} = Enrollment.create_oidc_profile(scope, attrs)
    assert Enrollment.list_profiles(scope) == []
    assert Enrollment.list_policies(scope) == []
    assert Enrollment.list_verifier_configurations(scope) == []
  end

  defp oidc_profile_attrs do
    %{
      name: "Production",
      selector: "production",
      issuer: "https://issuer.example",
      audience: "renga-agent",
      jwks_url: "https://issuer.example/jwks",
      algorithm: "EdDSA",
      subject_claim: "sub",
      subject_cardinality: "singleton",
      binding_mode: "challenge_bound",
      required_claim_path: "role",
      required_claim_value: "installer"
    }
  end
end
