defmodule Renga.EnrollmentTest do
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Enrollment
  alias Renga.Enrollment.{EnrollmentIdentity, EnrollmentPolicy}
  alias Renga.Repo

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

  for {label, create, attrs} <- [
        {"policies", :create_policy, %{name: "concurrent", document: %{}}},
        {"verifier configurations", :create_verifier_configuration,
         %{
           name: "concurrent",
           kind: "manual",
           subject_cardinality: "group",
           configuration: %{}
         }}
      ] do
    test "concurrent #{label} receive sequential versions", %{scope: scope} do
      results = concurrent_create(scope, unquote(create), unquote(Macro.escape(attrs)))
      assert Enum.map(results, & &1.version) |> Enum.sort() == Enum.to_list(1..8)
    end
  end

  test "concurrent OIDC profiles receive sequential policy and verifier versions", %{scope: scope} do
    owner = self()

    profiles =
      1..8
      |> Task.async_stream(
        fn index ->
          Sandbox.allow(Repo, owner, self())

          attrs =
            oidc_profile_attrs()
            |> Map.put(:name, "Concurrent OIDC")
            |> Map.put(:selector, "concurrent-#{index}")

          {:ok, profile} = Enrollment.create_oidc_profile(scope, attrs)
          profile
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, profile} -> profile end)

    assert length(profiles) == 8

    assert Enum.map(Enrollment.list_policies(scope), & &1.version) |> Enum.sort() ==
             Enum.to_list(1..8)

    assert Enum.map(Enrollment.list_verifier_configurations(scope), & &1.version) |> Enum.sort() ==
             Enum.to_list(1..8)
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

  test "identity issuer and subject are limited by UTF-8 byte length", %{
    organization: organization,
    scope: scope
  } do
    {:ok, verifier} =
      Enrollment.create_verifier_configuration(scope, %{
        name: "identity lengths",
        kind: "manual",
        subject_cardinality: "group",
        configuration: %{}
      })

    build = fn issuer, subject ->
      %EnrollmentIdentity{
        organization_id: organization.id,
        verifier_configuration_id: verifier.id
      }
      |> EnrollmentIdentity.changeset(%{
        issuer: issuer,
        subject: subject,
        subject_cardinality: "group"
      })
    end

    value_255 = String.duplicate("é", 127) <> "a"
    value_256 = String.duplicate("é", 128)
    assert build.(value_255, value_255).valid?
    refute build.(value_256, value_255).valid?
    refute build.(value_255, value_256).valid?
    assert {:ok, _} = build.(value_255, value_255) |> Repo.insert()

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "INSERT INTO enrollment_identities (id, organization_id, verifier_configuration_id, issuer, subject, subject_cardinality, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, 'group', NOW(), NOW())",
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(organization.id),
          Ecto.UUID.dump!(verifier.id),
          value_256,
          "subject"
        ]
      )
    end
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

  defp concurrent_create(scope, function, attrs) do
    owner = self()

    1..8
    |> Task.async_stream(
      fn _ ->
        Sandbox.allow(Repo, owner, self())
        {:ok, row} = apply(Enrollment, function, [scope, attrs])
        row
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, row} -> row end)
  end
end
