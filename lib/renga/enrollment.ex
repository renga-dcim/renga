defmodule Renga.Enrollment do
  @moduledoc "Organization-scoped administration of immutable enrollment versions and selectors."

  import Ecto.Query, warn: false

  alias Renga.Accounts.{Organization, OrganizationMembership, Scope}

  alias Renga.Enrollment.{
    AgentCredential,
    Canonical,
    CredentialEvent,
    EnrollmentAttempt,
    EnrollmentBinding,
    EnrollmentChallenge,
    EnrollmentDecision,
    EnrollmentIdentity,
    EnrollmentPolicy,
    EnrollmentProfile,
    EnrollmentReplay,
    ManualGrant,
    OIDC,
    OIDCProfileSetup,
    Policy,
    VerifierConfiguration
  }

  alias Renga.Inventory.{Agent, Source}
  alias Renga.Repo

  @credential_ttl_seconds 86_400

  def list_profiles(%Scope{organization_id: id}),
    do: scoped(EnrollmentProfile, id) |> order_by([r], r.selector) |> Repo.all()

  def list_policies(%Scope{organization_id: id}),
    do:
      scoped(EnrollmentPolicy, id)
      |> order_by([r], desc: r.version, asc: r.name, desc: r.inserted_at)
      |> Repo.all()

  def list_verifier_configurations(%Scope{organization_id: id}),
    do:
      scoped(VerifierConfiguration, id)
      |> order_by([r], desc: r.version, asc: r.name, desc: r.inserted_at)
      |> Repo.all()

  def get_profile!(%Scope{organization_id: id}, row_id),
    do: scoped(EnrollmentProfile, id) |> Repo.get!(row_id)

  def get_policy!(%Scope{organization_id: id}, row_id),
    do: scoped(EnrollmentPolicy, id) |> Repo.get!(row_id)

  def get_verifier_configuration!(%Scope{organization_id: id}, row_id),
    do: scoped(VerifierConfiguration, id) |> Repo.get!(row_id)

  def list_agent_credentials(%Scope{organization_id: id}) do
    scoped(AgentCredential, id) |> order_by([c], desc: c.inserted_at) |> Repo.all()
  end

  def get_agent_credential!(%Scope{organization_id: id}, credential_id),
    do: scoped(AgentCredential, id) |> Repo.get!(credential_id)

  @doc "Renews the same authenticated, active key without moving beyond the server horizon."
  def renew_agent_credential(
        %Scope{} = scope,
        %Source{} = source,
        %Agent{} = agent,
        %AgentCredential{} = credential
      ) do
    credential_transaction(scope.organization_id, source.id, agent.id, credential.id, fn locked,
                                                                                         now ->
      unless locked.status == "active" and DateTime.compare(locked.expires_at, now) == :gt and
               locked.credential_id == credential.credential_id and
               locked.public_key == credential.public_key,
             do: Repo.rollback(:agent_credential_changed)

      horizon = DateTime.add(now, @credential_ttl_seconds, :second)

      if DateTime.compare(locked.expires_at, horizon) == :gt,
        do: Repo.rollback(:credential_horizon_invalid)

      previous_expiry = locked.expires_at
      renewed = locked |> Ecto.Changeset.change(expires_at: horizon) |> Repo.update!()

      put_credential_event!(renewed, "renewed", now, %{
        "previous_expires_at" => DateTime.to_iso8601(previous_expiry),
        "expires_at" => DateTime.to_iso8601(horizon)
      })

      renewed
    end)
  end

  def revoke_agent_credential(%Scope{} = scope, credential_id),
    do: administer_credential(scope, credential_id, :revoke)

  def quarantine_agent_credential(%Scope{} = scope, credential_id),
    do: administer_credential(scope, credential_id, :quarantine)

  def unquarantine_agent_credential(%Scope{} = scope, credential_id),
    do: administer_credential(scope, credential_id, :unquarantine)

  defp administer_credential(scope, credential_id, action) do
    admin_transaction(scope, fn ->
      credential = scoped(AgentCredential, scope.organization_id) |> Repo.get(credential_id)
      if is_nil(credential), do: Repo.rollback(:not_found)

      credential_transaction(
        scope.organization_id,
        credential.source_id,
        credential.agent_id,
        credential.id,
        fn locked, now ->
          case {action, locked.status, DateTime.compare(locked.expires_at, now)} do
            {:revoke, "revoked", _} ->
              locked

            {:revoke, _, _} ->
              updated =
                locked
                |> Ecto.Changeset.change(status: "revoked", revoked_at: now)
                |> Repo.update!()

              put_credential_event!(updated, "revoked", now)
              updated

            {:quarantine, "active", :gt} ->
              updated = locked |> Ecto.Changeset.change(status: "quarantined") |> Repo.update!()
              put_credential_event!(updated, "quarantined", now)
              updated

            {:quarantine, "quarantined", :gt} ->
              locked

            {:unquarantine, "quarantined", :gt} ->
              updated = locked |> Ecto.Changeset.change(status: "active") |> Repo.update!()
              put_credential_event!(updated, "unquarantined", now)
              updated

            _ ->
              Repo.rollback(:invalid_credential_state)
          end
        end
      )
      |> case do
        {:ok, row} -> row
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp credential_transaction(organization_id, source_id, agent_id, credential_id, operation) do
    Repo.transaction(fn ->
      organization =
        Organization |> where([o], o.id == ^organization_id) |> lock("FOR UPDATE") |> Repo.one()

      if is_nil(organization), do: Repo.rollback(:agent_credential_changed)

      source =
        Source
        |> where([s], s.id == ^source_id and s.organization_id == ^organization.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if is_nil(source), do: Repo.rollback(:agent_credential_changed)

      agent =
        Agent
        |> where(
          [a],
          a.id == ^agent_id and a.source_id == ^source.id and
            a.organization_id == ^organization.id
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      if is_nil(agent), do: Repo.rollback(:agent_credential_changed)

      credential =
        AgentCredential
        |> where(
          [c],
          c.id == ^credential_id and c.agent_id == ^agent.id and c.source_id == ^source.id and
            c.organization_id == ^organization.id
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      if is_nil(credential), do: Repo.rollback(:agent_credential_changed)

      now = Renga.Time.utc_now_ms()

      unless organization.status == "active" and source.status == "active" and
               agent.status == "active",
             do: Repo.rollback(:agent_credential_changed)

      operation.(credential, now)
    end)
  end

  defp put_credential_event!(credential, kind, now, metadata \\ %{}) do
    %CredentialEvent{
      organization_id: credential.organization_id,
      agent_credential_id: credential.id
    }
    |> CredentialEvent.changeset(%{kind: kind, occurred_at: now, metadata: metadata})
    |> Repo.insert!()
  end

  @doc "Creates an optional, one-use manual verifier grant. The plaintext secret is returned only here."
  def create_manual_grant(%Scope{} = scope, profile_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, 900)

    if not is_integer(ttl) or ttl < 60 or ttl > 86_400,
      do: {:error, :invalid_expiry},
      else: do_create_manual_grant(scope, profile_id, ttl)
  end

  defp do_create_manual_grant(scope, profile_id, ttl) do
    public_id = :crypto.strong_rand_bytes(24)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(Renga.Time.utc_now_ms(), ttl, :second)

    case admin_transaction(scope, fn ->
           profile = scoped(EnrollmentProfile, scope.organization_id) |> Repo.get(profile_id)
           if is_nil(profile), do: Repo.rollback(:not_found)

           %ManualGrant{
             organization_id: scope.organization_id,
             enrollment_profile_id: profile.id,
             public_id: public_id,
             secret_hash: Argon2.hash_pwd_salt(secret)
           }
           |> ManualGrant.changeset(%{expires_at: expires_at})
           |> Repo.insert()
         end) do
      {:ok, grant} ->
        {:ok, grant, %{public_id: Base.url_encode64(public_id, padding: false), secret: secret}}

      error ->
        error
    end
  end

  @doc "Creates a short-lived challenge without accepting any caller-selected trust material."
  def create_challenge(org_slug, selector, installation_id, public_key)
      when is_binary(org_slug) and is_binary(selector) and is_binary(installation_id) and
             is_binary(public_key) do
    now = Renga.Time.utc_now_ms()
    nonce = :crypto.strong_rand_bytes(32)

    Repo.transaction(fn ->
      with %Organization{} = org <-
             Organization
             |> where([o], o.slug == ^org_slug and o.status == "active")
             |> Repo.one(),
           %EnrollmentProfile{} = profile <-
             EnrollmentProfile
             |> where([p], p.organization_id == ^org.id and p.selector == ^selector and p.enabled)
             |> Repo.one(),
           %VerifierConfiguration{kind: kind, enabled: true} = verifier
           when kind in ~w(manual oidc) <-
             Repo.get(VerifierConfiguration, profile.verifier_configuration_id),
           %EnrollmentPolicy{} = policy <-
             Repo.get(EnrollmentPolicy, profile.enrollment_policy_id) do
        challenge =
          %EnrollmentChallenge{
            organization_id: org.id,
            enrollment_profile_id: profile.id,
            enrollment_policy_id: policy.id,
            verifier_configuration_id: verifier.id
          }
          |> EnrollmentChallenge.changeset(%{
            installation_id: installation_id,
            public_key: public_key,
            key_thumbprint: :crypto.hash(:sha256, public_key),
            nonce_hash: :crypto.hash(:sha256, nonce),
            expires_at: DateTime.add(now, 300, :second)
          })
          |> Repo.insert!()

        %{
          id: challenge.id,
          nonce: Base.url_encode64(nonce, padding: false),
          expires_at: challenge.expires_at,
          transcript_version: "renga-enrollment-proof-v1"
        }
      else
        _ -> Repo.rollback(:not_found)
      end
    end)
  end

  @doc "Builds the exact domain-separated byte transcript signed by an installation key."
  def proof_transcript(challenge, nonce, evidence, requested, metadata) do
    Canonical.encode(%{
      "domain" => "renga/enrollment/proof",
      "version" => 1,
      "challenge_id" => challenge.id,
      "nonce" => nonce,
      "action" => challenge.action,
      "installation_id" => Ecto.UUID.cast!(challenge.installation_id),
      "key_thumbprint" => challenge.key_thumbprint,
      "evidence_sha256" => Canonical.digest(evidence),
      "requested_capabilities_sha256" => Canonical.digest(requested),
      "metadata_sha256" => Canonical.digest(metadata)
    })
  end

  def submit_attempt(challenge_id, nonce, evidence, requested, metadata, proof)
      when is_binary(challenge_id) and is_binary(nonce) and is_map(evidence) and
             is_list(requested) and is_map(metadata) and is_binary(proof) do
    with {:ok, challenge_id} <- Ecto.UUID.cast(challenge_id),
         %EnrollmentChallenge{} = challenge <- Repo.get(EnrollmentChallenge, challenge_id),
         true <- :crypto.hash(:sha256, nonce) == challenge.nonce_hash,
         :ok <- verify_attempt_proof(challenge, nonce, evidence, requested, metadata, proof) do
      digest =
        Canonical.digest(%{
          "evidence" => evidence,
          "requested_capabilities" => requested,
          "metadata" => metadata,
          "proof" => proof
        })

      case terminal_result(challenge, digest) do
        {:terminal, result} -> {:ok, result}
        :conflict -> {:error, :submission_conflict}
        :open -> verify_then_finalize(challenge, digest, nonce, evidence, requested, metadata)
      end
    else
      {:error, :invalid_request} -> {:error, :invalid_request}
      _ -> {:error, :invalid_proof}
    end
  end

  defp terminal_result(%EnrollmentChallenge{status: "open"}, _digest), do: :open

  defp terminal_result(
         %EnrollmentChallenge{submission_digest: digest, safe_result: result},
         digest
       ),
       do: {:terminal, result}

  defp terminal_result(_, _), do: :conflict

  defp verify_then_finalize(
         challenge,
         digest,
         nonce,
         %{"kind" => "oidc", "token" => token},
         requested,
         metadata
       )
       when is_binary(token) do
    with %VerifierConfiguration{kind: "oidc"} = verifier <-
           Repo.get(VerifierConfiguration, challenge.verifier_configuration_id),
         {:ok, verified} <-
           OIDC.verify(verifier.configuration, token, nonce, challenge.public_key) do
      finalize(challenge, digest, {:oidc_verified, verified}, requested, metadata)
    else
      {:error, reason} -> recover_terminal_result(challenge, digest, reason)
      _ -> recover_terminal_result(challenge, digest, :invalid_evidence)
    end
  end

  defp verify_then_finalize(challenge, digest, _nonce, evidence, requested, metadata),
    do: finalize(challenge, digest, evidence, requested, metadata)

  defp recover_terminal_result(challenge, digest, verifier_error) do
    Repo.transaction(fn ->
      Organization
      |> where([o], o.id == ^challenge.organization_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      EnrollmentProfile
      |> where([p], p.id == ^challenge.enrollment_profile_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      locked =
        EnrollmentChallenge
        |> where([c], c.id == ^challenge.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      case terminal_result(locked, digest) do
        {:terminal, result} -> result
        :conflict -> Repo.rollback(:submission_conflict)
        :open -> Repo.rollback(verifier_error)
      end
    end)
  end

  defp verify_attempt_proof(challenge, nonce, evidence, requested, metadata, proof) do
    if :crypto.verify(
         :eddsa,
         :none,
         proof_transcript(challenge, nonce, evidence, requested, metadata),
         proof,
         [challenge.public_key, :ed25519]
       ),
       do: :ok,
       else: {:error, :invalid_proof}
  rescue
    _error in [ArgumentError, FunctionClauseError] -> {:error, :invalid_request}
  catch
    :error, :badarg -> {:error, :invalid_request}
  end

  defp finalize(challenge, digest, evidence, requested, metadata) do
    Repo.transaction(fn ->
      finalize_locked(challenge.id, digest, evidence, requested, metadata)
    end)
  end

  defp finalize_locked(id, digest, evidence, requested, metadata) do
    challenge0 = Repo.get!(EnrollmentChallenge, id)

    org =
      Organization
      |> where([o], o.id == ^challenge0.organization_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    profile =
      EnrollmentProfile
      |> where([p], p.id == ^challenge0.enrollment_profile_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    challenge =
      EnrollmentChallenge |> where([c], c.id == ^id) |> lock("FOR UPDATE") |> Repo.one!()

    verifier =
      VerifierConfiguration
      |> where([v], v.id == ^challenge.verifier_configuration_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    policy =
      EnrollmentPolicy
      |> where([p], p.id == ^challenge.enrollment_policy_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    cond do
      challenge.status != "open" and challenge.submission_digest == digest ->
        challenge.safe_result

      challenge.status != "open" ->
        Repo.rollback(:submission_conflict)

      DateTime.compare(challenge.expires_at, Renga.Time.utc_now_ms()) != :gt ->
        response = %{status: "expired"}
        terminalize(challenge, "expired", digest, response, Renga.Time.utc_now_ms())
        response

      org.status != "active" or not profile.enabled or not verifier.enabled or
        profile.organization_id != challenge.organization_id or
        verifier.organization_id != challenge.organization_id or
        policy.organization_id != challenge.organization_id or
        profile.enrollment_policy_id != challenge.enrollment_policy_id or
          profile.verifier_configuration_id != challenge.verifier_configuration_id ->
        Repo.rollback(:unavailable)

      true ->
        case {verifier.kind, evidence} do
          {"manual", evidence} ->
            verify_manual(
              challenge,
              profile,
              verifier,
              policy,
              digest,
              evidence,
              requested,
              metadata
            )

          {"oidc", {:oidc_verified, verified}} ->
            finalize_oidc(challenge, profile, verifier, policy, digest, verified, requested)

          _ ->
            Repo.rollback(:invalid_evidence)
        end
    end
  end

  defp finalize_oidc(challenge, profile, verifier, policy, digest, verified, requested) do
    replay = verified.replay_digest

    if replay, do: consume_oidc_replay(challenge, verifier, verified, replay)

    decision =
      Policy.evaluate(
        policy.document,
        %{"verified" => verified.envelope, "server" => %{"profile" => profile.selector}},
        requested
      )

    persist_decision(
      challenge,
      verifier,
      policy,
      nil,
      verified.envelope,
      verified.evidence_digest,
      digest,
      decision,
      Renga.Time.utc_now_ms()
    )
  end

  defp consume_oidc_replay(challenge, verifier, verified, replay) do
    %EnrollmentReplay{
      organization_id: challenge.organization_id,
      verifier_configuration_id: verifier.id
    }
    |> EnrollmentReplay.changeset(%{
      kind: "oidc_digest",
      value_hash: replay,
      expires_at:
        DateTime.from_unix!(
          verified.envelope["expires_at"] + verifier.configuration["clock_skew_seconds"],
          :second
        )
    })
    |> Repo.insert()
    |> case do
      {:ok, replay} -> replay
      {:error, %Ecto.Changeset{}} -> Repo.rollback(:invalid_evidence)
    end
  end

  defp verify_manual(
         challenge,
         profile,
         verifier,
         policy,
         digest,
         %{"kind" => "manual", "public_id" => encoded, "secret" => secret},
         requested,
         _metadata
       )
       when is_binary(encoded) and is_binary(secret) do
    with {:ok, public_id} <- Base.url_decode64(encoded, padding: false),
         %ManualGrant{} = grant <-
           ManualGrant
           |> where(
             [g],
             g.organization_id == ^challenge.organization_id and
               g.enrollment_profile_id == ^profile.id and g.public_id == ^public_id
           )
           |> lock("FOR UPDATE")
           |> Repo.one(),
         true <- Argon2.verify_pass(secret, grant.secret_hash),
         :ok <- usable_grant(grant, challenge) do
      now = Renga.Time.utc_now_ms()
      issuer = "manual:" <> Map.get(verifier.configuration, "issuer_namespace", profile.selector)

      envelope = %{
        "issuer" => issuer,
        "subject" => encoded,
        "assurance" => "manual_grant",
        "provenance" => %{"kind" => "manual_grant", "verified" => true},
        "issued_at" => DateTime.to_iso8601(grant.inserted_at),
        "expires_at" => DateTime.to_iso8601(grant.expires_at),
        "verifier_key" => %{
          "kty" => "manual",
          "kid" => Base.url_encode64(:crypto.hash(:sha256, verifier.id), padding: false)
        }
      }

      decision =
        Policy.evaluate(
          policy.document,
          %{
            "verified" => envelope,
            "server" => %{"profile" => profile.selector}
          },
          requested
        )

      persist_decision(
        challenge,
        verifier,
        policy,
        grant,
        envelope,
        Canonical.digest(%{
          "kind" => "manual",
          "public_id" => encoded,
          "secret" => secret
        }),
        digest,
        decision,
        now
      )
    else
      _ -> Repo.rollback(:invalid_evidence)
    end
  end

  defp verify_manual(_, _, _, _, _, _, _, _), do: Repo.rollback(:invalid_evidence)

  defp usable_grant(%ManualGrant{accepted_at: nil, expires_at: expires_at}, _challenge) do
    if DateTime.compare(expires_at, Renga.Time.utc_now_ms()) == :gt,
      do: :ok,
      else: {:error, :expired}
  end

  defp usable_grant(%ManualGrant{accepted_enrollment_binding_id: binding_id}, challenge)
       when not is_nil(binding_id) do
    case Repo.get(EnrollmentBinding, binding_id) do
      %EnrollmentBinding{status: "active"} = binding
      when binding.installation_id == challenge.installation_id and
             binding.key_thumbprint == challenge.key_thumbprint ->
        :ok

      _ ->
        {:error, :already_used}
    end
  end

  defp usable_grant(_, _), do: {:error, :already_used}

  defp persist_decision(
         challenge,
         verifier,
         policy,
         grant,
         envelope,
         evidence_digest,
         digest,
         {outcome, result},
         now
       ) do
    attempt =
      %EnrollmentAttempt{
        organization_id: challenge.organization_id,
        enrollment_challenge_id: challenge.id,
        enrollment_policy_id: policy.id,
        verifier_configuration_id: verifier.id
      }
      |> EnrollmentAttempt.changeset(%{
        normalized_envelope: envelope,
        evidence_digest: evidence_digest,
        status: "verified"
      })
      |> Repo.insert!()

    {final_outcome, final_result, action} =
      if outcome == :allow do
        resolve_allow(challenge, verifier, policy, grant, envelope, digest, result, now)
      else
        {:deny, result, nil}
      end

    attrs = %{
      outcome: Atom.to_string(final_outcome),
      reason: final_result.reason,
      assurance: envelope["assurance"],
      provenance: envelope["provenance"],
      condition_ids: Map.get(final_result, :condition_ids, []),
      assignments: Map.get(final_result, :assignments, %{}),
      grants: Map.get(final_result, :grants, []),
      verifier_key_thumbprint:
        decode_thumbprint(envelope["verifier_key_thumbprint"]) ||
          :crypto.hash(:sha256, verifier.id),
      safe_public_jwk: envelope["verifier_key"],
      evaluated_at: now
    }

    %EnrollmentDecision{
      organization_id: challenge.organization_id,
      enrollment_attempt_id: attempt.id
    }
    |> EnrollmentDecision.changeset(attrs)
    |> Repo.insert!()

    if final_outcome == :deny do
      response = %{status: "denied", reason: final_result.reason}
      terminalize(challenge, "denied", digest, response, now)
      response
    else
      action.()
    end
  end

  defp resolve_allow(challenge, verifier, policy, grant, envelope, digest, result, now) do
    # A transaction-scoped identity lock closes the gap where two transactions both see no row.
    identity_lock_key =
      Enum.join(
        [challenge.organization_id, verifier.id, envelope["issuer"], envelope["subject"]],
        ":"
      )

    installation_lock_key =
      Enum.join([challenge.organization_id, Ecto.UUID.cast!(challenge.installation_id)], ":")

    [identity_lock_key, installation_lock_key]
    |> Enum.sort()
    |> Enum.each(fn lock_key ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])
    end)

    identity =
      EnrollmentIdentity
      |> where(
        [i],
        i.organization_id == ^challenge.organization_id and
          i.verifier_configuration_id == ^verifier.id and i.issuer == ^envelope["issuer"] and
          i.subject == ^envelope["subject"]
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    identity =
      identity ||
        %EnrollmentIdentity{
          organization_id: challenge.organization_id,
          verifier_configuration_id: verifier.id
        }
        |> EnrollmentIdentity.changeset(%{
          issuer: envelope["issuer"],
          subject: envelope["subject"],
          subject_cardinality: verifier.subject_cardinality
        })
        |> Repo.insert!()

    existing =
      EnrollmentBinding
      |> where(
        [b],
        b.organization_id == ^challenge.organization_id and
          b.enrollment_identity_id == ^identity.id and b.status == "active"
      )
      |> lock("FOR UPDATE")
      |> Repo.all()

    same =
      Enum.find(
        existing,
        &(&1.installation_id == challenge.installation_id and
            &1.key_thumbprint == challenge.key_thumbprint)
      )

    installation_binding =
      EnrollmentBinding
      |> where(
        [b],
        b.organization_id == ^challenge.organization_id and
          b.installation_id == ^challenge.installation_id and b.status == "active"
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      same ->
        effective_result =
          result
          |> Map.put(:assignments, same.assignments)
          |> Map.put(:grants, same.grants)

        {:allow, effective_result, fn -> stable_existing(challenge, grant, digest, same, now) end}

      installation_binding ->
        {:deny, %{reason: "installation_already_bound", condition_ids: []}, nil}

      verifier.subject_cardinality == "singleton" and existing != [] ->
        {:deny, %{reason: "identity_cardinality_exceeded", condition_ids: []}, nil}

      verifier.subject_cardinality == "group" and group_limit(policy) == :error ->
        {:deny, %{reason: "invalid_policy", condition_ids: []}, nil}

      verifier.subject_cardinality == "group" and length(existing) >= group_limit(policy) ->
        {:deny, %{reason: "identity_cardinality_exceeded", condition_ids: []}, nil}

      true ->
        {:allow, result,
         fn -> create_collector(challenge, identity, grant, digest, result, now) end}
    end
  end

  defp create_collector(challenge, identity, grant, digest, result, now) do
    source =
      %Source{organization_id: challenge.organization_id}
      |> Source.changeset(%{
        kind: "host_agent",
        name: "enrolled-" <> Ecto.UUID.cast!(challenge.installation_id),
        metadata: %{}
      })
      |> Repo.insert!()

    agent =
      %Agent{
        organization_id: challenge.organization_id,
        source_id: source.id,
        installation_id: challenge.installation_id
      }
      |> Agent.changeset(%{
        name: source.name,
        registered_at: now,
        capabilities: [],
        metadata: %{}
      })
      |> Repo.insert!()

    binding =
      %EnrollmentBinding{
        organization_id: challenge.organization_id,
        enrollment_identity_id: identity.id,
        source_id: source.id,
        agent_id: agent.id,
        installation_id: challenge.installation_id,
        public_key: challenge.public_key,
        key_thumbprint: challenge.key_thumbprint
      }
      |> EnrollmentBinding.changeset(%{assignments: result.assignments, grants: result.grants})
      |> Repo.insert!()

    credential =
      %AgentCredential{
        organization_id: challenge.organization_id,
        source_id: source.id,
        agent_id: agent.id,
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: challenge.public_key,
        key_thumbprint: challenge.key_thumbprint
      }
      |> AgentCredential.changeset(%{
        expires_at: DateTime.add(now, @credential_ttl_seconds, :second)
      })
      |> Repo.insert!()

    %CredentialEvent{
      organization_id: challenge.organization_id,
      agent_credential_id: credential.id
    }
    |> CredentialEvent.changeset(%{kind: "issued", occurred_at: now})
    |> Repo.insert!()

    consume_grant(grant, binding, now)

    response = %{
      status: "accepted",
      source_id: source.id,
      agent_id: agent.id,
      credential_id: Base.url_encode64(credential.credential_id, padding: false),
      credential_expires_at: DateTime.to_iso8601(credential.expires_at),
      assignments: result.assignments,
      grants: result.grants
    }

    terminalize(challenge, "accepted", digest, response, now)
    response
  end

  defp stable_existing(challenge, grant, digest, binding, now) do
    credential =
      AgentCredential
      |> where([c], c.agent_id == ^binding.agent_id and c.status == "active")
      |> Repo.one!()

    consume_grant(grant, binding, now)

    response = %{
      status: "accepted",
      source_id: binding.source_id,
      agent_id: binding.agent_id,
      credential_id: Base.url_encode64(credential.credential_id, padding: false),
      credential_expires_at: DateTime.to_iso8601(credential.expires_at),
      assignments: binding.assignments,
      grants: binding.grants
    }

    terminalize(challenge, "accepted", digest, response, now)
    response
  end

  defp consume_grant(%ManualGrant{accepted_at: nil} = grant, binding, now),
    do:
      grant
      |> Ecto.Changeset.change(accepted_at: now, accepted_enrollment_binding_id: binding.id)
      |> Repo.update!()

  defp consume_grant(%ManualGrant{}, _binding, _now), do: :ok
  defp consume_grant(nil, _binding, _now), do: :ok

  defp terminalize(challenge, status, digest, response, now),
    do:
      challenge
      |> Ecto.Changeset.change(
        status: status,
        terminal_at: now,
        submission_digest: digest,
        safe_result: response
      )
      |> Repo.update!()

  defp group_limit(policy) do
    case get_in(policy.document, ["limits", "max_active"]) do
      n when is_integer(n) and n > 0 and n <= 10_000 -> n
      _ -> :error
    end
  end

  def create_policy(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      name = fetch_attr(attrs, :name)

      %EnrollmentPolicy{
        organization_id: scope.organization_id,
        created_by_membership_id: scope.membership_id
      }
      |> EnrollmentPolicy.changeset(
        put_attr(attrs, :version, next_version(EnrollmentPolicy, scope.organization_id, name))
      )
      |> Repo.insert()
    end)
  end

  def create_verifier_configuration(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      name = fetch_attr(attrs, :name)

      %VerifierConfiguration{
        organization_id: scope.organization_id,
        created_by_membership_id: scope.membership_id
      }
      |> VerifierConfiguration.changeset(
        put_attr(
          attrs,
          :version,
          next_version(VerifierConfiguration, scope.organization_id, name)
        )
      )
      |> Repo.insert()
    end)
  end

  def create_profile(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      %EnrollmentProfile{organization_id: scope.organization_id}
      |> EnrollmentProfile.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc "Atomically creates immutable policy/verifier versions and their mutable profile selector."
  def create_oidc_profile(%Scope{} = scope, attrs) do
    admin_transaction(scope, fn ->
      setup_changeset = OIDCProfileSetup.changeset(%OIDCProfileSetup{}, attrs)

      if not setup_changeset.valid?, do: Repo.rollback(setup_changeset)

      setup = Ecto.Changeset.apply_changes(setup_changeset)
      claim_path = OIDCProfileSetup.path(setup.required_claim_path)

      policy_document = %{
        "rule" => %{
          "id" => "required-oidc-claim",
          "attribute" => ["verified", "claims" | claim_path],
          "operator" => "eq",
          "value" => setup.required_claim_value
        }
      }

      policy_document =
        if setup.subject_cardinality == "group",
          do: Map.put(policy_document, "limits", %{"max_active" => setup.group_max}),
          else: policy_document

      policy =
        %EnrollmentPolicy{
          organization_id: scope.organization_id,
          created_by_membership_id: scope.membership_id
        }
        |> EnrollmentPolicy.changeset(%{
          name: setup.name,
          version: next_version(EnrollmentPolicy, scope.organization_id, setup.name),
          document: policy_document
        })
        |> Repo.insert!()

      verifier =
        %VerifierConfiguration{
          organization_id: scope.organization_id,
          created_by_membership_id: scope.membership_id
        }
        |> VerifierConfiguration.changeset(%{
          name: setup.name,
          version: next_version(VerifierConfiguration, scope.organization_id, setup.name),
          kind: "oidc",
          subject_cardinality: setup.subject_cardinality,
          configuration: OIDCProfileSetup.configuration(setup_changeset)
        })
        |> Repo.insert!()

      %EnrollmentProfile{organization_id: scope.organization_id}
      |> EnrollmentProfile.changeset(%{
        name: setup.name,
        selector: setup.selector,
        enrollment_policy_id: policy.id,
        verifier_configuration_id: verifier.id
      })
      |> Repo.insert()
    end)
  end

  def disable_profile(%Scope{} = scope, id),
    do: disable(scope, EnrollmentProfile, id, &EnrollmentProfile.disable_changeset/2)

  def disable_verifier_configuration(%Scope{} = scope, id),
    do: disable(scope, VerifierConfiguration, id, &VerifierConfiguration.disable_changeset/2)

  defp disable(scope, schema, id, changeset) do
    admin_transaction(scope, fn ->
      case scoped(schema, scope.organization_id)
           |> where([r], r.id == ^id)
           |> lock("FOR UPDATE")
           |> Repo.one() do
        nil -> Repo.rollback(:not_found)
        row -> row |> changeset.(Renga.Time.utc_now_ms()) |> Repo.update()
      end
    end)
  end

  defp next_version(schema, organization_id, name) do
    schema
    |> where([r], r.organization_id == ^organization_id)
    |> where([r], r.name == ^name)
    |> select([r], coalesce(max(r.version), 0) + 1)
    |> Repo.one()
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp put_attr(attrs, key, value) do
    if Enum.all?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, Atom.to_string(key), value)
    else
      Map.put(attrs, key, value)
    end
  end

  defp scoped(schema, organization_id),
    do: where(schema, [r], r.organization_id == ^organization_id)

  defp admin_transaction(%Scope{} = scope, operation) do
    Repo.transaction(fn ->
      active_org =
        Organization
        |> where([o], o.id == ^scope.organization_id and o.status == "active")
        |> lock("FOR UPDATE")
        |> Repo.exists?()

      authorized =
        OrganizationMembership
        |> where(
          [m],
          m.id == ^scope.membership_id and m.organization_id == ^scope.organization_id
        )
        |> where(
          [m],
          m.user_id == ^user_id(scope) and m.status == "active" and m.role in ["owner", "admin"]
        )
        |> lock("FOR UPDATE")
        |> Repo.exists?()

      unless active_org and authorized, do: Repo.rollback(:forbidden)

      case operation.() do
        {:ok, row} -> row
        {:error, reason} -> Repo.rollback(reason)
        row -> row
      end
    end)
  end

  defp user_id(%Scope{user: %{id: id}}), do: id
  defp user_id(_scope), do: nil

  defp decode_thumbprint(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> decoded
      _ -> nil
    end
  end

  defp decode_thumbprint(_value), do: nil
end
