defmodule Renga.Repo.Migrations.CreateEnrollmentModel do
  use Ecto.Migration

  def change do
    create table(:enrollment_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :version, :integer, null: false
      add :document, :map, null: false

      add :created_by_membership_id,
          references(:organization_memberships, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:enrollment_policies, [:id, :organization_id])
    create unique_index(:enrollment_policies, [:organization_id, :name, :version])

    create constraint(:enrollment_policies, :enrollment_policies_version_positive,
             check: "version > 0"
           )

    create constraint(:enrollment_policies, :enrollment_policies_document_size,
             check: "octet_length(document::text) <= 65536"
           )

    create table(:verifier_configurations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :version, :integer, null: false
      add :kind, :string, null: false
      add :subject_cardinality, :string, null: false
      add :configuration, :map, null: false
      add :enabled, :boolean, null: false, default: true
      add :disabled_at, :"timestamp(3)"

      add :created_by_membership_id,
          references(:organization_memberships, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:verifier_configurations, [:id, :organization_id])
    create unique_index(:verifier_configurations, [:organization_id, :name, :version])

    create constraint(:verifier_configurations, :verifier_configurations_version_positive,
             check: "version > 0"
           )

    create constraint(:verifier_configurations, :verifier_configurations_cardinality,
             check: "subject_cardinality IN ('singleton','group')"
           )

    create constraint(:verifier_configurations, :verifier_configurations_enabled_state,
             check:
               "(enabled AND disabled_at IS NULL) OR (NOT enabled AND disabled_at IS NOT NULL)"
           )

    create table(:enrollment_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :selector, :string, null: false
      add :name, :string, null: false
      add :enrollment_policy_id, :binary_id, null: false
      add :verifier_configuration_id, :binary_id, null: false
      add :enabled, :boolean, null: false, default: true
      add :disabled_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:enrollment_profiles, [:id, :organization_id])
    create unique_index(:enrollment_profiles, [:organization_id, :selector])

    create constraint(:enrollment_profiles, :enrollment_profiles_enabled_state,
             check:
               "(enabled AND disabled_at IS NULL) OR (NOT enabled AND disabled_at IS NOT NULL)"
           )

    tenant_fk(:enrollment_profiles, :enrollment_policy_id, :enrollment_policies)
    tenant_fk(:enrollment_profiles, :verifier_configuration_id, :verifier_configurations)

    create table(:enrollment_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enrollment_profile_id, :binary_id, null: false
      add :enrollment_policy_id, :binary_id, null: false
      add :verifier_configuration_id, :binary_id, null: false
      add :installation_id, :uuid, null: false
      add :action, :string, null: false, default: "collector:enroll"
      add :public_key, :binary, null: false
      add :key_thumbprint, :binary, null: false
      add :nonce_hash, :binary, null: false
      add :status, :string, null: false, default: "open"
      add :expires_at, :"timestamp(3)", null: false
      add :terminal_at, :"timestamp(3)"
      add :submission_digest, :binary
      add :safe_result, :map
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:enrollment_challenges, [:id, :organization_id])
    create unique_index(:enrollment_challenges, [:organization_id, :nonce_hash])
    create index(:enrollment_challenges, [:organization_id, :status, :expires_at])
    tenant_fk(:enrollment_challenges, :enrollment_profile_id, :enrollment_profiles)
    tenant_fk(:enrollment_challenges, :enrollment_policy_id, :enrollment_policies)
    tenant_fk(:enrollment_challenges, :verifier_configuration_id, :verifier_configurations)

    create constraint(:enrollment_challenges, :enrollment_challenges_crypto_lengths,
             check:
               "octet_length(public_key)=32 AND octet_length(key_thumbprint)=32 AND octet_length(nonce_hash)=32 AND (submission_digest IS NULL OR octet_length(submission_digest)=32)"
           )

    create constraint(:enrollment_challenges, :enrollment_challenges_action,
             check: "action = 'collector:enroll'"
           )

    create constraint(:enrollment_challenges, :enrollment_challenges_terminal_state,
             check:
               "(status='open' AND terminal_at IS NULL AND submission_digest IS NULL AND safe_result IS NULL) OR (status IN ('accepted','denied','expired') AND terminal_at IS NOT NULL AND ((status='expired' AND submission_digest IS NULL) OR (submission_digest IS NOT NULL AND safe_result IS NOT NULL)))"
           )

    create table(:enrollment_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :verifier_configuration_id, :binary_id, null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :subject_cardinality, :string, null: false
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:enrollment_identities, [:id, :organization_id])

    create unique_index(
             :enrollment_identities,
             [:organization_id, :verifier_configuration_id, :issuer, :subject],
             name: :enrollment_identities_namespace_index
           )

    tenant_fk(:enrollment_identities, :verifier_configuration_id, :verifier_configurations)

    create constraint(:enrollment_identities, :enrollment_identities_cardinality,
             check: "subject_cardinality IN ('singleton','group')"
           )

    create table(:enrollment_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enrollment_identity_id, :binary_id, null: false
      add :source_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false
      add :installation_id, :uuid, null: false
      add :public_key, :binary, null: false
      add :key_thumbprint, :binary, null: false
      add :assignments, :map, null: false, default: %{}
      add :grants, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "active"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:enrollment_bindings, [:id, :organization_id])

    create unique_index(:enrollment_bindings, [
             :organization_id,
             :installation_id,
             :key_thumbprint
           ])

    create unique_index(:agents, [:id, :organization_id, :source_id],
             name: :agents_id_organization_source_index
           )

    tenant_fk(:enrollment_bindings, :enrollment_identity_id, :enrollment_identities)

    execute "ALTER TABLE enrollment_bindings ADD CONSTRAINT enrollment_bindings_agent_source_fkey FOREIGN KEY (agent_id, organization_id, source_id) REFERENCES agents(id, organization_id, source_id)",
            "ALTER TABLE enrollment_bindings DROP CONSTRAINT enrollment_bindings_agent_source_fkey"

    create constraint(:enrollment_bindings, :enrollment_bindings_crypto_lengths,
             check: "octet_length(public_key)=32 AND octet_length(key_thumbprint)=32"
           )

    create constraint(:enrollment_bindings, :enrollment_bindings_status,
             check: "status IN ('active','disabled','replaced')"
           )

    create table(:enrollment_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enrollment_challenge_id, :binary_id, null: false
      add :enrollment_policy_id, :binary_id, null: false
      add :verifier_configuration_id, :binary_id, null: false
      add :normalized_envelope, :map
      add :evidence_digest, :binary, null: false
      add :status, :string, null: false
      add :reason, :string
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:enrollment_attempts, [:id, :organization_id])
    create index(:enrollment_attempts, [:organization_id, :enrollment_challenge_id])
    tenant_fk(:enrollment_attempts, :enrollment_challenge_id, :enrollment_challenges)
    tenant_fk(:enrollment_attempts, :enrollment_policy_id, :enrollment_policies)
    tenant_fk(:enrollment_attempts, :verifier_configuration_id, :verifier_configurations)

    create constraint(:enrollment_attempts, :enrollment_attempts_valid,
             check:
               "octet_length(evidence_digest)=32 AND status IN ('received','verified','rejected','unavailable') AND ((status IN ('verified','rejected') AND normalized_envelope IS NOT NULL) OR (status IN ('received','unavailable') AND normalized_envelope IS NULL))"
           )

    create table(:enrollment_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enrollment_attempt_id, :binary_id, null: false
      add :outcome, :string, null: false
      add :reason, :string, null: false
      add :assurance, :string, null: false
      add :provenance, :map, null: false
      add :condition_ids, {:array, :string}, null: false, default: []
      add :assignments, :map, null: false, default: %{}
      add :grants, {:array, :string}, null: false, default: []
      add :verifier_key_thumbprint, :binary, null: false
      add :safe_public_jwk, :map, null: false
      add :evaluated_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    tenant_fk(:enrollment_decisions, :enrollment_attempt_id, :enrollment_attempts)
    create unique_index(:enrollment_decisions, [:organization_id, :enrollment_attempt_id])

    create constraint(:enrollment_decisions, :enrollment_decisions_valid,
             check:
               "outcome IN ('allow','deny') AND octet_length(verifier_key_thumbprint)=32 AND safe_public_jwk ? 'kty' AND safe_public_jwk ? 'kid'"
           )

    create table(:agent_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source_id, :binary_id, null: false
      add :agent_id, :binary_id, null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :key_thumbprint, :binary, null: false
      add :status, :string, null: false, default: "active"
      add :expires_at, :"timestamp(3)", null: false
      add :revoked_at, :"timestamp(3)"
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:agent_credentials, [:id, :organization_id])
    create unique_index(:agent_credentials, [:credential_id])

    create unique_index(:agent_credentials, [:organization_id, :agent_id],
             where: "status='active'",
             name: :agent_credentials_current_active_index
           )

    execute "ALTER TABLE agent_credentials ADD CONSTRAINT agent_credentials_agent_source_fkey FOREIGN KEY (agent_id, organization_id, source_id) REFERENCES agents(id, organization_id, source_id)",
            "ALTER TABLE agent_credentials DROP CONSTRAINT agent_credentials_agent_source_fkey"

    create constraint(:agent_credentials, :agent_credentials_valid,
             check:
               "octet_length(credential_id)>=32 AND octet_length(public_key)=32 AND octet_length(key_thumbprint)=32 AND ((status IN ('active','quarantined') AND revoked_at IS NULL) OR (status IN ('revoked','expired') AND revoked_at IS NOT NULL))"
           )

    create table(:credential_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_credential_id, :binary_id, null: false
      add :kind, :string, null: false
      add :occurred_at, :"timestamp(3)", null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    tenant_fk(:credential_events, :agent_credential_id, :agent_credentials)
    create index(:credential_events, [:organization_id, :agent_credential_id, :occurred_at])

    create table(:enrollment_replays, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :verifier_configuration_id, :binary_id
      add :agent_credential_id, :binary_id
      add :kind, :string, null: false
      add :value_hash, :binary, null: false
      add :expires_at, :"timestamp(3)", null: false
      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    tenant_fk(:enrollment_replays, :verifier_configuration_id, :verifier_configurations)
    tenant_fk(:enrollment_replays, :agent_credential_id, :agent_credentials)

    create unique_index(
             :enrollment_replays,
             [:organization_id, :verifier_configuration_id, :kind, :value_hash],
             where: "verifier_configuration_id IS NOT NULL",
             name: :enrollment_replays_verifier_index
           )

    create unique_index(
             :enrollment_replays,
             [:organization_id, :agent_credential_id, :kind, :value_hash],
             where: "agent_credential_id IS NOT NULL",
             name: :enrollment_replays_credential_index
           )

    create constraint(:enrollment_replays, :enrollment_replays_owner_and_hash,
             check:
               "octet_length(value_hash)=32 AND ((verifier_configuration_id IS NOT NULL AND agent_credential_id IS NULL AND kind IN ('oidc_digest','oidc_jti')) OR (verifier_configuration_id IS NULL AND agent_credential_id IS NOT NULL AND kind='runtime_nonce'))"
           )

    create index(:enrollment_replays, [:expires_at])

    create table(:manual_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :enrollment_profile_id, :binary_id, null: false
      add :public_id, :binary, null: false
      add :secret_hash, :string, null: false
      add :expires_at, :"timestamp(3)", null: false
      add :accepted_at, :"timestamp(3)"
      add :accepted_enrollment_binding_id, :binary_id
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:manual_grants, [:public_id])
    tenant_fk(:manual_grants, :enrollment_profile_id, :enrollment_profiles)
    tenant_fk(:manual_grants, :accepted_enrollment_binding_id, :enrollment_bindings)

    create constraint(:manual_grants, :manual_grants_valid,
             check:
               "octet_length(public_id)>=16 AND secret_hash LIKE '$argon2%' AND ((accepted_at IS NULL AND accepted_enrollment_binding_id IS NULL) OR (accepted_at IS NOT NULL AND accepted_enrollment_binding_id IS NOT NULL))"
           )

    execute "CREATE FUNCTION reject_enrollment_immutable_update() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'enrollment audit/version rows are immutable' USING ERRCODE='integrity_constraint_violation'; END; $$ LANGUAGE plpgsql",
            "DROP FUNCTION reject_enrollment_immutable_update()"

    execute "CREATE FUNCTION protect_verifier_configuration() RETURNS trigger AS $$ BEGIN IF NEW.organization_id IS DISTINCT FROM OLD.organization_id OR NEW.name IS DISTINCT FROM OLD.name OR NEW.version IS DISTINCT FROM OLD.version OR NEW.kind IS DISTINCT FROM OLD.kind OR NEW.subject_cardinality IS DISTINCT FROM OLD.subject_cardinality OR NEW.configuration IS DISTINCT FROM OLD.configuration OR NEW.created_by_membership_id IS DISTINCT FROM OLD.created_by_membership_id OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN RAISE EXCEPTION 'verifier trust configuration is immutable' USING ERRCODE='integrity_constraint_violation'; END IF; RETURN NEW; END; $$ LANGUAGE plpgsql",
            "DROP FUNCTION protect_verifier_configuration()"

    execute "CREATE TRIGGER verifier_configurations_protect_trust BEFORE UPDATE ON verifier_configurations FOR EACH ROW EXECUTE FUNCTION protect_verifier_configuration()",
            "DROP TRIGGER verifier_configurations_protect_trust ON verifier_configurations"

    immutable(:enrollment_policies)
    immutable(:enrollment_attempts)
    immutable(:enrollment_decisions)
    immutable(:credential_events)
  end

  defp tenant_fk(table, column, target) do
    execute "ALTER TABLE #{table} ADD CONSTRAINT #{table}_#{column}_tenant_fkey FOREIGN KEY (#{column}, organization_id) REFERENCES #{target}(id, organization_id)",
            "ALTER TABLE #{table} DROP CONSTRAINT #{table}_#{column}_tenant_fkey"
  end

  defp immutable(table) do
    execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE ON #{table} FOR EACH ROW EXECUTE FUNCTION reject_enrollment_immutable_update()",
            "DROP TRIGGER #{table}_immutable ON #{table}"
  end
end
