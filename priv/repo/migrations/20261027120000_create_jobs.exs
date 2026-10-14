defmodule Renga.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  # RFD 9: durable jobs leased by agents. The job row is a projection of its
  # append-only events; Renga.Jobs writes both in one transaction.
  def change do
    create table(:jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      # NO ACTION rather than RESTRICT so organization teardown, which cascades
      # to agents and jobs in one statement, is checked only once both are gone.
      add :agent_id,
          references(:agents,
            with: [organization_id: :organization_id],
            on_delete: :nothing,
            type: :binary_id,
            name: :jobs_tenant_agent_fkey
          ),
          null: false

      add :batch_id, :binary_id
      add :capability, :string, null: false
      add :capability_version, :integer, null: false
      # Snapshots of the capability's fixed classes, so the sweeper never needs
      # the capability module and a job's retry rule cannot change after it was
      # requested.
      add :risk_class, :string, null: false
      add :retry_class, :string, null: false
      add :parameters, :map, null: false, default: %{}
      add :requested_by_type, :string, null: false

      add :requested_by_user_id,
          references(:users, on_delete: :nilify_all, type: :binary_id)

      add :idempotency_key, :string
      add :state, :string, null: false
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false
      add :not_after, :"timestamp(3)", null: false
      add :lease_token_hash, :binary
      add :leased_at, :"timestamp(3)"
      add :lease_expires_at, :"timestamp(3)"
      add :started_at, :"timestamp(3)"
      add :cancel_requested_at, :"timestamp(3)"
      add :finished_at, :"timestamp(3)"
      add :result, :map
      add :failure_reason, :string
      add :output_bytes, :integer, null: false, default: 0
      add :output_limit_bytes, :integer, null: false
      add :timeout_ms, :integer, null: false
      add :last_sequence, :integer, null: false, default: 0

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:jobs, [:id, :organization_id])

    create unique_index(:jobs, [:organization_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :jobs_organization_idempotency_key_index
           )

    create index(:jobs, [:organization_id, :agent_id, :inserted_at],
             where: "state = 'queued'",
             name: :jobs_queued_agent_index
           )

    create index(:jobs, [:lease_expires_at],
             where: "state IN ('leased', 'running')",
             name: :jobs_active_lease_expiry_index
           )

    create index(:jobs, [:not_after],
             where: "state = 'queued'",
             name: :jobs_queued_deadline_index
           )

    create index(:jobs, [:organization_id, :finished_at],
             where: "finished_at IS NOT NULL",
             name: :jobs_finished_index
           )

    create index(:jobs, [:organization_id, :inserted_at])

    create index(:jobs, [:organization_id, :batch_id], where: "batch_id IS NOT NULL")

    create constraint(:jobs, :jobs_valid_state,
             check:
               "state IN ('queued', 'leased', 'running', 'succeeded', 'failed', 'cancelled', 'expired', 'uncertain')"
           )

    create constraint(:jobs, :jobs_valid_classes,
             check:
               "risk_class IN ('observe', 'operate', 'interactive') AND retry_class IN ('idempotent', 'convergent', 'imperative')"
           )

    create constraint(:jobs, :jobs_valid_requester,
             check:
               "requested_by_type IN ('user', 'system') AND (requested_by_type = 'user' OR requested_by_user_id IS NULL)"
           )

    create constraint(:jobs, :jobs_valid_capability,
             check:
               "capability <> '' AND capability_version > 0 AND (idempotency_key IS NULL OR idempotency_key <> '')"
           )

    create constraint(:jobs, :jobs_valid_attempts,
             check: "max_attempts >= 1 AND attempts BETWEEN 0 AND max_attempts"
           )

    create constraint(:jobs, :jobs_valid_limits,
             check:
               "timeout_ms > 0 AND output_limit_bytes > 0 AND output_bytes BETWEEN 0 AND output_limit_bytes AND last_sequence >= 0"
           )

    # Only a held lease has a token, and every held lease has one.
    create constraint(:jobs, :jobs_lease_shape,
             check: """
             (state IN ('leased', 'running')) =
               (lease_token_hash IS NOT NULL AND leased_at IS NOT NULL AND lease_expires_at IS NOT NULL)
             """
           )

    create constraint(:jobs, :jobs_started_shape,
             check: "state <> 'running' OR started_at IS NOT NULL"
           )

    # `uncertain` is not finished: it waits for a person or reconciliation.
    create constraint(:jobs, :jobs_finished_shape,
             check: """
             (state IN ('succeeded', 'failed', 'cancelled', 'expired')) = (finished_at IS NOT NULL)
             """
           )

    create constraint(:jobs, :jobs_uncertain_only_imperative,
             check: "state <> 'uncertain' OR retry_class = 'imperative'"
           )

    create table(:job_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :job_id,
          references(:jobs,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :job_events_tenant_job_fkey
          ),
          null: false

      add :sequence, :integer, null: false
      add :attempt, :integer, null: false
      add :type, :string, null: false
      add :actor_type, :string, null: false
      # Not a foreign key: a user or agent removed later must not rewrite the
      # history, and these rows cannot be updated to nilify it.
      add :actor_id, :binary_id
      add :payload, :map, null: false, default: %{}

      add :inserted_at, :"timestamp(3)", null: false
    end

    create unique_index(:job_events, [:job_id, :sequence])
    create index(:job_events, [:organization_id, :inserted_at])

    create constraint(:job_events, :job_events_valid_type,
             check: """
             type IN ('created', 'leased', 'started', 'progress', 'output', 'succeeded', 'failed',
                      'cancel_requested', 'cancelled', 'lease_lost', 'expired', 'uncertain', 'resolved')
             """
           )

    create constraint(:job_events, :job_events_valid_actor,
             check: """
             (actor_type = 'system' AND actor_id IS NULL) OR
               (actor_type IN ('user', 'agent') AND actor_id IS NOT NULL)
             """
           )

    create constraint(:job_events, :job_events_valid_position,
             check: "sequence > 0 AND attempt >= 0"
           )

    create constraint(:job_events, :job_events_payload_size,
             check: "octet_length(payload::text) <= 65536"
           )

    execute(
      """
      CREATE FUNCTION reject_job_event_change() RETURNS trigger AS $$
      BEGIN
        -- Retention removes a finished job and organization teardown removes the
        -- organization; both delete the parent row before cascading here, so a
        -- delete that outlives its job or organization is the only one allowed.
        IF TG_OP = 'DELETE' AND (
          NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) OR
          NOT EXISTS (SELECT 1 FROM jobs WHERE id = OLD.job_id)
        ) THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'job events are append-only'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION reject_job_event_change()"
    )

    execute(
      """
      CREATE TRIGGER job_events_append_only
      BEFORE UPDATE OR DELETE ON job_events
      FOR EACH ROW EXECUTE FUNCTION reject_job_event_change()
      """,
      "DROP TRIGGER job_events_append_only ON job_events"
    )
  end
end
