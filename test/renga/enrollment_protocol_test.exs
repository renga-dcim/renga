defmodule Renga.EnrollmentProtocolTest do
  use Renga.DataCase, async: false

  import Ecto.Query
  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Renga.Accounts
  alias Renga.Enrollment

  alias Renga.Enrollment.{
    AgentCredential,
    CredentialEvent,
    EnrollmentAttempt,
    EnrollmentBinding,
    EnrollmentChallenge,
    EnrollmentDecision,
    EnrollmentReplay,
    ManualGrant
  }

  alias Renga.Inventory.{Agent, Source}
  alias Renga.Repo

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    Req.Test.set_req_test_to_shared(Enrollment.OIDC)
    Application.put_env(:renga, :oidc_resolver, fn _ -> {:ok, [{8, 8, 8, 8}]} end)
    bundle = enrollment_fixture()
    Map.put(bundle, :sandbox_owner, self())
  end

  test "allow atomically creates the narrowed collector aggregate and consumes its grant",
       fixture do
    submission = signed_submission(fixture, ["inventory:read", "not-granted"])
    assert {:ok, %{status: "accepted"} = result} = submit(submission)

    source = Repo.get!(Source, result.source_id)
    agent = Repo.get!(Agent, result.agent_id)
    binding = Repo.one!(EnrollmentBinding)
    credential = Repo.one!(AgentCredential)
    grant = Repo.get!(ManualGrant, fixture.grant.id)

    assert source.token_hash == nil
    assert agent.capabilities == []
    assert binding.assignments == %{"site" => "lab"}
    assert binding.grants == ["inventory:read"]
    assert credential.agent_id == agent.id
    assert Repo.aggregate(CredentialEvent, :count) == 1
    assert Repo.one!(CredentialEvent).kind == "issued"
    assert Repo.aggregate(EnrollmentDecision, :count) == 1
    assert Repo.one!(EnrollmentDecision).outcome == "allow"
    assert grant.accepted_at && grant.accepted_enrollment_binding_id == binding.id
  end

  test "an enrolled collector cannot be reset or lose enrollment provenance", fixture do
    assert {:ok, %{status: "accepted", source_id: source_id}} =
             fixture |> signed_submission(["inventory:read"]) |> submit()

    source = Repo.get!(Source, source_id)
    agent = Repo.one!(Agent)
    binding = Repo.one!(EnrollmentBinding)
    credential = Repo.one!(AgentCredential)

    assert {:error, :key_bound_enrollment} =
             Renga.Inventory.reset_collector_enrollment(fixture.scope, source.id)

    assert {:error, :key_bound_enrollment} =
             Renga.Inventory.rotate_collector_token(fixture.scope, source.id)

    assert {:error, :key_bound_enrollment} =
             Renga.Inventory.rotate_source_token(fixture.scope, source.id)

    assert Repo.reload!(source) == source
    assert Repo.reload!(agent) == agent
    assert Repo.reload!(binding) == binding
    assert Repo.reload!(credential) == credential
  end

  test "policy deny is terminal and audited without consuming the grant" do
    fixture = enrollment_fixture(policy: deny_policy())
    assert {:ok, %{status: "denied"}} = fixture |> signed_submission([]) |> submit()

    assert Repo.get!(EnrollmentChallenge, fixture.challenge.id).status == "denied"
    assert Repo.aggregate(EnrollmentAttempt, :count) == 1
    assert Repo.one!(EnrollmentDecision).outcome == "deny"
    assert Repo.aggregate(EnrollmentBinding, :count) == 0
    assert Repo.aggregate(Source, :count) == 0
    assert Repo.get!(ManualGrant, fixture.grant.id).accepted_at == nil
  end

  test "bad proof leaves the challenge open", fixture do
    submission = %{signed_submission(fixture, []) | proof: :crypto.strong_rand_bytes(64)}
    assert {:error, :invalid_proof} = submit(submission)
    assert Repo.get!(EnrollmentChallenge, fixture.challenge.id).status == "open"
    assert Repo.aggregate(EnrollmentAttempt, :count) == 0
  end

  test "concurrent public issuance at the profile cap cannot overrun it", fixture do
    limit = Enrollment.open_challenge_limit()

    existing =
      Repo.aggregate(
        from(c in EnrollmentChallenge, where: c.enrollment_profile_id == ^fixture.profile.id),
        :count
      )

    for _ <- 1..(limit - existing) do
      assert {:ok, _} = issue_challenge(fixture)
    end

    results =
      1..4
      |> Enum.map(fn _ -> fn -> issue_challenge(fixture) end end)
      |> concurrently_calls(fixture.sandbox_owner)

    assert Enum.all?(results, &match?({:error, :not_found}, &1))

    assert Repo.aggregate(
             from(c in EnrollmentChallenge,
               where: c.enrollment_profile_id == ^fixture.profile.id and c.status == "open"
             ),
             :count
           ) == limit
  end

  test "expired open challenges are reclaimed before applying the cap", fixture do
    limit = Enrollment.open_challenge_limit()

    for _ <- 1..(limit - 1), do: assert({:ok, _} = issue_challenge(fixture))

    expired_id = fixture.challenge.id
    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^expired_id),
      set: [expires_at: past]
    )

    assert {:ok, _} = issue_challenge(fixture)
    refute Repo.get(EnrollmentChallenge, expired_id)
  end

  test "exact terminal retry is stable despite expiry while a changed signed request conflicts",
       fixture do
    submission = signed_submission(fixture, ["inventory:read"])
    assert {:ok, first} = submit(submission)
    past = DateTime.add(Renga.Time.utc_now_ms(), -60, :second)

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^fixture.challenge.id),
      set: [expires_at: past]
    )

    Repo.update_all(from(g in ManualGrant, where: g.id == ^fixture.grant.id),
      set: [expires_at: past]
    )

    assert {:ok, retried} = submit(submission)
    assert retried["credential_id"] == first.credential_id
    changed = signed_submission(fixture, [], nonce: submission.nonce)
    assert {:error, :submission_conflict} = submit(changed)
    assert Repo.aggregate(EnrollmentBinding, :count) == 1
  end

  test "a submission-driven expiry is terminal and replay-stable", fixture do
    past = DateTime.add(Renga.Time.utc_now_ms(), -60, :second)

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^fixture.challenge.id),
      set: [expires_at: past]
    )

    submission = signed_submission(fixture, [])
    assert {:ok, %{status: "expired"}} = submit(submission)
    assert {:ok, %{"status" => "expired"}} = submit(submission)

    changed = signed_submission(fixture, ["inventory:read"], nonce: submission.nonce)
    assert {:error, :submission_conflict} = submit(changed)
    assert Repo.aggregate(EnrollmentAttempt, :count) == 0
  end

  test "a fresh challenge for an existing binding audits its authoritative grants", fixture do
    assert {:ok, %{status: "accepted", grants: []}} =
             fixture |> signed_submission([]) |> submit()

    second = challenge_fixture(fixture, fixture.challenge.installation_id)
    submission = signed_submission(%{fixture | challenge: second}, ["inventory:read"])

    assert {:ok, %{status: "accepted", grants: []}} = submit(submission)
    assert Enum.all?(Repo.all(EnrollmentDecision), &(&1.grants == []))
    assert Repo.one!(EnrollmentBinding).grants == []
  end

  test "concurrent submissions of one challenge converge on one aggregate and result", fixture do
    submission = signed_submission(fixture, ["inventory:read"])
    results = concurrently(fixture.sandbox_owner, [submission, submission])

    assert [{:ok, first}, {:ok, second}] = results
    assert Jason.decode!(Jason.encode!(first)) == Jason.decode!(Jason.encode!(second))
    assert Repo.aggregate(EnrollmentBinding, :count) == 1
    assert Repo.aggregate(AgentCredential, :count) == 1
  end

  test "two challenges racing for one grant allow at most one new binding without task exits",
       fixture do
    second = challenge_fixture(fixture, Ecto.UUID.generate())

    submissions = [
      signed_submission(fixture, []),
      signed_submission(%{fixture | challenge: second}, [])
    ]

    results = concurrently(fixture.sandbox_owner, submissions)

    assert Enum.all?(results, &(match?({:ok, _}, &1) or match?({:error, :invalid_evidence}, &1)))
    assert Enum.count(results, &match?({:ok, %{status: "accepted"}}, &1)) <= 1
    assert Repo.aggregate(EnrollmentBinding, :count) <= 1
  end

  test "organization, profile, and verifier disablement block submission without side effects" do
    for disabled <- [:organization, :profile, :verifier] do
      fixture = enrollment_fixture()

      case disabled do
        :organization ->
          fixture.organization |> Ecto.Changeset.change(status: "disabled") |> Repo.update!()

        :profile ->
          assert {:ok, _} = Enrollment.disable_profile(fixture.scope, fixture.profile.id)

        :verifier ->
          assert {:ok, _} =
                   Enrollment.disable_verifier_configuration(fixture.scope, fixture.verifier.id)
      end

      assert {:error, :unavailable} = fixture |> signed_submission([]) |> submit()

      assert Repo.aggregate(
               from(a in EnrollmentAttempt, where: a.organization_id == ^fixture.organization.id),
               :count
             ) == 0

      assert Repo.aggregate(
               from(b in EnrollmentBinding, where: b.organization_id == ^fixture.organization.id),
               :count
             ) == 0
    end
  end

  test "a grant issued for another profile is rejected while the challenge remains open",
       fixture do
    {:ok, other_profile} =
      Enrollment.create_profile(fixture.scope, %{
        selector: "other",
        name: "Other",
        enrollment_policy_id: fixture.policy.id,
        verifier_configuration_id: fixture.verifier.id
      })

    {:ok, _grant, secret} = Enrollment.create_manual_grant(fixture.scope, other_profile.id)
    submission = signed_submission(%{fixture | secret: secret}, [])

    assert {:error, :invalid_evidence} = submit(submission)
    assert Repo.get!(EnrollmentChallenge, fixture.challenge.id).status == "open"
  end

  test "OIDC policy authorizes a typed claim and persists only safe key evidence" do
    fixture = oidc_fixture()
    submission = oidc_submission(fixture)
    assert {:ok, %{status: "accepted"} = result} = submit(submission)

    source = Repo.get!(Source, result.source_id)
    binding = Repo.one!(EnrollmentBinding)
    decision = Repo.one!(EnrollmentDecision)
    assert source.token_hash == nil

    assert decision.verifier_key_thumbprint ==
             JOSE.JWK.thumbprint(fixture.oidc_key) |> Base.url_decode64!(padding: false)

    assert decision.safe_public_jwk == fixture.oidc_public

    refute inspect(binding) =~ submission.evidence["token"]
    refute inspect(decision) =~ submission.evidence["token"]
  end

  test "exact OIDC retry is stable after token expiry and verifier key configuration changes" do
    fixture = oidc_fixture()
    submission = oidc_submission(fixture)
    assert {:ok, first} = submit(submission)
    past = DateTime.add(Renga.Time.utc_now_ms(), -60, :second)
    replacement = oidc_public(JOSE.JWK.generate_key({:okp, :Ed25519}), "replacement")

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^fixture.challenge.id),
      set: [expires_at: past]
    )

    Repo.query!("ALTER TABLE verifier_configurations DISABLE TRIGGER USER")

    Repo.update_all(
      from(v in Enrollment.VerifierConfiguration, where: v.id == ^fixture.verifier.id),
      set: [configuration: Map.put(fixture.verifier.configuration, "jwks", [replacement])]
    )

    Repo.query!("ALTER TABLE verifier_configurations ENABLE TRIGGER USER")

    assert {:ok, retried} = submit(submission)
    assert retried["credential_id"] == first.credential_id
    assert Repo.aggregate(EnrollmentBinding, :count) == 1
  end

  test "OIDC re-enrollment reauthorizes the same key after its credential expires" do
    fixture = oidc_fixture()
    assert {:ok, first} = fixture |> oidc_submission() |> submit()
    credential = Repo.one!(AgentCredential)
    expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(from(c in AgentCredential, where: c.id == ^credential.id),
      set: [expires_at: expired_at]
    )

    challenge = challenge_fixture(fixture, fixture.challenge.installation_id)
    submission = oidc_submission(%{fixture | challenge: challenge})

    assert {:ok, second} = submit(submission)
    reauthorized = Repo.get!(AgentCredential, credential.id)

    assert second.credential_id == first.credential_id
    assert second.source_id == first.source_id
    assert second.agent_id == first.agent_id
    assert DateTime.compare(reauthorized.expires_at, Renga.Time.utc_now_ms()) == :gt
    assert Repo.aggregate(EnrollmentBinding, :count) == 1

    assert Enum.map(Repo.all(from e in CredentialEvent, order_by: e.inserted_at), & &1.kind) ==
             ["issued", "reauthorized"]
  end

  test "OIDC re-enrollment rejects inactive or key-mismatched existing aggregates" do
    for invalid <- [:source, :agent, :credential_key] do
      fixture = oidc_fixture()
      assert {:ok, first} = fixture |> oidc_submission() |> submit()
      binding = Repo.get_by!(EnrollmentBinding, agent_id: first.agent_id)
      credential = Repo.get_by!(AgentCredential, agent_id: first.agent_id)
      expired_at = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

      Repo.update_all(from(c in AgentCredential, where: c.id == ^credential.id),
        set: [expires_at: expired_at]
      )

      case invalid do
        :source ->
          Repo.update_all(from(s in Source, where: s.id == ^binding.source_id),
            set: [status: "revoked"]
          )

        :agent ->
          Repo.update_all(from(a in Agent, where: a.id == ^binding.agent_id),
            set: [status: "disabled"]
          )

        :credential_key ->
          Repo.update_all(from(c in AgentCredential, where: c.id == ^credential.id),
            set: [public_key: :crypto.strong_rand_bytes(32)]
          )
      end

      challenge = challenge_fixture(fixture, fixture.challenge.installation_id)
      assert {:error, :unavailable} = submit(oidc_submission(%{fixture | challenge: challenge}))
      assert Repo.get!(AgentCredential, credential.id).expires_at == expired_at

      assert Repo.aggregate(
               from(e in CredentialEvent, where: e.agent_credential_id == ^credential.id),
               :count
             ) == 1
    end
  end

  test "cleanup deleting an expired challenge during remote verification returns a safe error" do
    fixture = oidc_fixture(remote: true)
    submission = oidc_submission(fixture)
    parent = self()
    sandbox_owner = self()

    Req.Test.expect(Enrollment.OIDC, fn conn ->
      send(parent, :verification_paused)
      assert_receive :resume_verification, 5_000
      Req.Test.json(conn, %{"keys" => [fixture.oidc_public]})
    end)

    task =
      Task.async(fn ->
        assert Sandbox.allow(Repo, sandbox_owner, self()) in [:ok, :not_found]
        submit(submission)
      end)

    assert_receive :verification_paused, 5_000
    past = DateTime.add(Renga.Time.utc_now_ms(), -1, :second)

    Repo.update_all(from(c in EnrollmentChallenge, where: c.id == ^fixture.challenge.id),
      set: [expires_at: past]
    )

    assert %{challenges: 1} = Enrollment.Cleanup.cleanup_once()
    send(task.pid, :resume_verification)
    assert {:error, :expired} = Task.await(task, 5_000)
    refute Repo.get(EnrollmentChallenge, fixture.challenge.id)
  end

  test "bearer-unbound OIDC replay and policy denial both consume the digest" do
    for policy <- [oidc_allow_policy(), deny_policy()] do
      fixture = oidc_fixture(binding_mode: "bearer_unbound", policy: policy)
      token = oidc_token(fixture, false)
      first = oidc_submission(fixture, token)
      second_challenge = challenge_fixture(fixture, Ecto.UUID.generate())
      second = oidc_submission(%{fixture | challenge: second_challenge}, token)

      assert {:ok, _} = submit(first)
      assert {:error, :invalid_evidence} = submit(second)

      assert Repo.aggregate(
               from(r in EnrollmentReplay, where: r.organization_id == ^fixture.organization.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(b in EnrollmentBinding, where: b.organization_id == ^fixture.organization.id),
               :count
             ) <= 1
    end
  end

  test "singleton OIDC identity serializes distinct installation challenges" do
    sandbox_owner = self()
    fixture = oidc_fixture()
    submissions = distinct_oidc_submissions(fixture, 2)

    results = concurrently(sandbox_owner, submissions)

    assert Enum.count(results, &match?({:ok, %{status: "accepted"}}, &1)) == 1

    assert [{:ok, %{status: "denied", reason: "identity_cardinality_exceeded"}} = denied] =
             Enum.filter(results, &match?({:ok, %{status: "denied"}}, &1))

    denied_index = Enum.find_index(results, &(&1 == denied))
    denied_submission = Enum.at(submissions, denied_index)

    assert {:ok, %{"status" => "denied", "reason" => "identity_cardinality_exceeded"}} =
             submit(denied_submission)

    assert Repo.aggregate(from(b in EnrollmentBinding, where: b.status == "active"), :count) == 1
  end

  test "group OIDC identity races never exceed the policy active-binding limit" do
    sandbox_owner = self()
    policy = put_in(oidc_allow_policy(), ["limits"], %{"max_active" => 2})
    fixture = oidc_fixture(policy: policy, subject_cardinality: "group")
    submissions = distinct_oidc_submissions(fixture, 3)

    results = concurrently(sandbox_owner, submissions)

    assert Enum.count(results, &match?({:ok, %{status: "accepted"}}, &1)) == 2

    assert Enum.count(
             results,
             &match?(
               {:ok, %{status: "denied", reason: "identity_cardinality_exceeded"}},
               &1
             )
           ) == 1

    assert Repo.aggregate(from(b in EnrollmentBinding, where: b.status == "active"), :count) == 2
  end

  # Manual grants have unique subjects, so singleton/group cardinality cannot be
  # meaningfully exercised without fabricating verifier semantics.
  defp enrollment_fixture(opts \\ []) do
    user = user_fixture()
    organization = organization_fixture()
    organization_membership_fixture(user, organization, %{role: "owner"})
    scope = Accounts.scope_for_user(user, organization.id)

    {:ok, policy} =
      Enrollment.create_policy(scope, %{
        name: "protocol",
        document: Keyword.get(opts, :policy, allow_policy())
      })

    {:ok, verifier} =
      Enrollment.create_verifier_configuration(scope, %{
        name: "manual",
        kind: "manual",
        subject_cardinality: "singleton",
        configuration: %{}
      })

    selector = "profile-#{System.unique_integer([:positive])}"

    {:ok, profile} =
      Enrollment.create_profile(scope, %{
        selector: selector,
        name: "Enrollment",
        enrollment_policy_id: policy.id,
        verifier_configuration_id: verifier.id
      })

    {:ok, grant, secret} = Enrollment.create_manual_grant(scope, profile.id)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    fixture = %{
      user: user,
      organization: organization,
      scope: scope,
      policy: policy,
      verifier: verifier,
      profile: profile,
      grant: grant,
      secret: secret,
      public: public,
      private: private
    }

    Map.put(fixture, :challenge, challenge_fixture(fixture, Ecto.UUID.generate()))
  end

  defp oidc_fixture(opts \\ []) do
    key = JOSE.JWK.generate_key({:okp, :Ed25519})
    public = oidc_public(key, "oidc-#{System.unique_integer([:positive])}")
    base = enrollment_fixture(policy: Keyword.get(opts, :policy, oidc_allow_policy()))

    configuration =
      if Keyword.get(opts, :remote, false) do
        public
        |> oidc_config(Keyword.get(opts, :binding_mode, "challenge_bound"))
        |> Map.delete("jwks")
        |> Map.merge(%{
          "jwks_url" => "https://issuer.example/jwks",
          "http_timeout_ms" => 2_000,
          "max_jwks_staleness_seconds" => 60
        })
      else
        oidc_config(public, Keyword.get(opts, :binding_mode, "challenge_bound"))
      end

    {:ok, verifier} =
      Enrollment.create_verifier_configuration(base.scope, %{
        name: "oidc",
        kind: "oidc",
        subject_cardinality: Keyword.get(opts, :subject_cardinality, "singleton"),
        configuration: configuration
      })

    {:ok, profile} =
      Enrollment.create_profile(base.scope, %{
        selector: "oidc-#{System.unique_integer([:positive])}",
        name: "OIDC",
        enrollment_policy_id: base.policy.id,
        verifier_configuration_id: verifier.id
      })

    fixture =
      %{base | verifier: verifier, profile: profile}
      |> Map.merge(%{oidc_key: key, oidc_public: public})

    %{fixture | challenge: challenge_fixture(fixture, Ecto.UUID.generate())}
  end

  defp oidc_submission(fixture, token \\ nil) do
    evidence = %{"kind" => "oidc", "token" => token || oidc_token(fixture, true)}
    metadata = %{"agent_version" => "test"}

    transcript =
      Enrollment.proof_transcript(
        fixture.challenge,
        fixture.challenge.decoded_nonce,
        evidence,
        [],
        metadata
      )

    %{
      challenge: fixture.challenge,
      nonce: fixture.challenge.decoded_nonce,
      evidence: evidence,
      requested: [],
      metadata: metadata,
      proof: :crypto.sign(:eddsa, :none, transcript, [fixture.private, :ed25519])
    }
  end

  defp distinct_oidc_submissions(fixture, count) do
    for _ <- 1..count do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)

      challenge_fixture =
        fixture
        |> Map.merge(%{public: public, private: private})
        |> then(&Map.put(&1, :challenge, challenge_fixture(&1, Ecto.UUID.generate())))

      oidc_submission(challenge_fixture)
    end
  end

  defp oidc_token(fixture, bound?) do
    now = System.system_time(:second)

    claims = %{
      "iss" => "https://issuer.example",
      "aud" => "renga-agent",
      "sub" => "subject-1",
      "role" => "installer",
      "iat" => now,
      "nbf" => now,
      "exp" => now + 300
    }

    claims =
      if bound?,
        do:
          Map.merge(claims, %{
            "nonce" => Base.url_encode64(fixture.challenge.decoded_nonce, padding: false),
            "cnf" => %{"jkt" => installation_thumbprint(fixture.public)}
          }),
        else: claims

    fixture.oidc_key
    |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => fixture.oidc_public["kid"]}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp oidc_config(public, mode),
    do: %{
      "issuer" => "https://issuer.example",
      "audiences" => ["renga-agent"],
      "algorithms" => ["EdDSA"],
      "subject_claim" => ["sub"],
      "max_token_age_seconds" => 300,
      "max_token_lifetime_seconds" => 600,
      "clock_skew_seconds" => 0,
      "binding_mode" => mode,
      "required_claims" => [%{"path" => ["role"], "type" => "string"}],
      "jwks" => [public]
    }

  defp oidc_public(key, kid),
    do:
      key
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"kid" => kid, "alg" => "EdDSA"})

  defp installation_thumbprint(public),
    do:
      JOSE.JWK.thumbprint(
        JOSE.JWK.from_map(%{
          "kty" => "OKP",
          "crv" => "Ed25519",
          "x" => Base.url_encode64(public, padding: false)
        })
      )

  defp challenge_fixture(fixture, installation_id) do
    {:ok, contract} =
      Enrollment.create_challenge(
        fixture.organization.slug,
        fixture.profile.selector,
        installation_id,
        fixture.public
      )

    Repo.get!(EnrollmentChallenge, contract.id)
    |> Map.put(:decoded_nonce, Base.url_decode64!(contract.nonce, padding: false))
  end

  defp issue_challenge(fixture) do
    Enrollment.create_challenge(
      fixture.organization.slug,
      fixture.profile.selector,
      Ecto.UUID.generate(),
      fixture.public
    )
  end

  defp concurrently_calls(calls, caller) do
    calls
    |> Enum.map(fn call ->
      Task.async(fn ->
        Sandbox.allow(Repo, caller, self())
        call.()
      end)
    end)
    |> Task.await_many(10_000)
  end

  defp signed_submission(fixture, requested, opts \\ []) do
    nonce = Keyword.get(opts, :nonce, fixture.challenge.decoded_nonce)

    evidence = %{
      "kind" => "manual",
      "public_id" => fixture.secret.public_id,
      "secret" => fixture.secret.secret
    }

    metadata = %{"agent_version" => "test"}

    transcript =
      Enrollment.proof_transcript(fixture.challenge, nonce, evidence, requested, metadata)

    proof = :crypto.sign(:eddsa, :none, transcript, [fixture.private, :ed25519])

    %{
      challenge: fixture.challenge,
      nonce: nonce,
      evidence: evidence,
      requested: requested,
      metadata: metadata,
      proof: proof
    }
  end

  defp submit(s),
    do:
      Enrollment.submit_attempt(
        s.challenge.id,
        s.nonce,
        s.evidence,
        s.requested,
        s.metadata,
        s.proof
      )

  defp concurrently(owner, submissions) do
    submissions
    |> Task.async_stream(
      fn submission ->
        # Shared mode may have already granted access before this explicit allowance.
        assert Sandbox.allow(Repo, owner, self()) in [:ok, :not_found]
        submit(submission)
      end,
      max_concurrency: length(submissions),
      timeout: 10_000,
      ordered: true
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp allow_policy,
    do: %{
      "rule" => %{
        "id" => "verified",
        "attribute" => ["verified", "assurance"],
        "operator" => "eq",
        "value" => "manual_grant"
      },
      "assignments" => %{"site" => "lab"},
      "grants" => ["inventory:read"]
    }

  defp deny_policy,
    do: %{
      "rule" => %{
        "id" => "deny",
        "attribute" => ["server", "profile"],
        "operator" => "eq",
        "value" => "never"
      }
    }

  defp oidc_allow_policy,
    do: %{
      "rule" => %{
        "id" => "role",
        "attribute" => ["verified", "claims", "role"],
        "operator" => "eq",
        "value" => "installer"
      }
    }
end
