defmodule Renga.Repo.Migrations.CreateCableIntentAndCables do
  use Ecto.Migration

  # Cable intent (`cable_plans`), attributed claims (`cable_assertions`), and the
  # reconciled `cables` projection stay separate so a plan never reserves a port
  # and neighbor evidence never rewrites confirmed cabling. Only `cables` rows
  # occupy an endpoint, which the termination table and its triggers enforce.
  def change do
    create table(:cable_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_a_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_plans_tenant_a_fkey
          ),
          null: false

      add :interface_b_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_plans_tenant_b_fkey
          ),
          null: false

      add :cable_type, :string
      add :status, :string, null: false, default: "planned"
      add :label, :string
      add :color, :string
      add :length_value, :numeric, precision: 12, scale: 3
      add :length_unit, :string
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:cable_plans, [:organization_id, :interface_a_id, :interface_b_id],
             name: :cable_plans_endpoints_index
           )

    create unique_index(:cable_plans, [:id, :organization_id])
    create index(:cable_plans, [:organization_id, :interface_a_id], name: :cable_plans_a_index)
    create index(:cable_plans, [:organization_id, :interface_b_id], name: :cable_plans_b_index)

    create constraint(:cable_plans, :cable_plans_canonical_order,
             check: "interface_a_id < interface_b_id"
           )

    create constraint(:cable_plans, :cable_plans_valid_status,
             check: "status IN ('planned', 'connected', 'decommissioning')"
           )

    create constraint(:cable_plans, :cable_plans_valid_length_unit,
             check: "length_unit IS NULL OR length_unit IN ('m', 'cm', 'ft', 'in')"
           )

    create constraint(:cable_plans, :cable_plans_length_pair,
             check: "(length_value IS NULL) = (length_unit IS NULL)"
           )

    create constraint(:cable_plans, :cable_plans_positive_length,
             check: "length_value IS NULL OR length_value > 0"
           )

    create constraint(:cable_plans, :cable_plans_color_format,
             check: "color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$'"
           )

    create table(:cable_assertions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Insertion order breaks ties when two claims share a millisecond
      # `asserted_at`, so the newest claim is deterministic rather than
      # whichever random UUID happens to sort higher.
      add :sequence, :bigserial, null: false

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_a_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_assertions_tenant_a_fkey
          ),
          null: false

      add :interface_b_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_assertions_tenant_b_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :action, :string, null: false
      add :confirmation, :string, null: false

      # Retention: assertions are append-only provenance, so deleting an actor
      # must not rewrite or orphan the claim. Deleting a user with claims is
      # rejected instead of nullifying the attribution.
      add :actor_user_id, references(:users, on_delete: :restrict, type: :binary_id)

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_assertions_tenant_source_fkey
          )

      add :interface_neighbor_evidence_id,
          references(:interface_neighbor_evidence,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_assertions_tenant_evidence_fkey
          )

      add :asserted_at, :"timestamp(3)", null: false
      add :cable_type, :string
      add :status, :string
      add :label, :string
      add :color, :string
      add :length_value, :numeric, precision: 12, scale: 3
      add :length_unit, :string
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:cable_assertions, [:id, :organization_id])

    create index(:cable_assertions, [:organization_id, :interface_a_id, :asserted_at],
             name: :cable_assertions_a_index
           )

    create index(:cable_assertions, [:organization_id, :interface_b_id, :asserted_at],
             name: :cable_assertions_b_index
           )

    create index(:cable_assertions, [:organization_id, :kind, :asserted_at],
             name: :cable_assertions_kind_index
           )

    create constraint(:cable_assertions, :cable_assertions_canonical_order,
             check: "interface_a_id < interface_b_id"
           )

    create constraint(:cable_assertions, :cable_assertions_valid_kind,
             check: "kind IN ('operator', 'import', 'neighbor_evidence')"
           )

    create constraint(:cable_assertions, :cable_assertions_valid_action,
             check: "action IN ('assert', 'retract')"
           )

    create constraint(:cable_assertions, :cable_assertions_valid_confirmation,
             check: "confirmation IN ('confirmed', 'proposed')"
           )

    create constraint(:cable_assertions, :cable_assertions_attribution_shape,
             check: """
             (
               (kind = 'operator' AND actor_user_id IS NOT NULL AND source_id IS NULL AND interface_neighbor_evidence_id IS NULL)
               OR (kind = 'import' AND actor_user_id IS NULL AND source_id IS NOT NULL AND interface_neighbor_evidence_id IS NULL)
               OR (kind = 'neighbor_evidence' AND actor_user_id IS NULL AND source_id IS NULL AND interface_neighbor_evidence_id IS NOT NULL)
             ) IS TRUE
             """
           )

    create constraint(:cable_assertions, :cable_assertions_confirmation_shape,
             check:
               "((kind = 'neighbor_evidence') AND confirmation = 'proposed') OR ((kind <> 'neighbor_evidence') AND confirmation = 'confirmed')"
           )

    create constraint(:cable_assertions, :cable_assertions_retract_shape,
             check: """
             action = 'assert' OR (
               cable_type IS NULL AND status IS NULL AND label IS NULL AND color IS NULL AND
               length_value IS NULL AND length_unit IS NULL AND description IS NULL AND metadata = '{}'::jsonb
             )
             """
           )

    create constraint(:cable_assertions, :cable_assertions_valid_status,
             check: "status IS NULL OR status IN ('planned', 'connected', 'decommissioning')"
           )

    create constraint(:cable_assertions, :cable_assertions_valid_length_unit,
             check: "length_unit IS NULL OR length_unit IN ('m', 'cm', 'ft', 'in')"
           )

    create constraint(:cable_assertions, :cable_assertions_length_pair,
             check: "(length_value IS NULL) = (length_unit IS NULL)"
           )

    create constraint(:cable_assertions, :cable_assertions_positive_length,
             check: "length_value IS NULL OR length_value > 0"
           )

    create constraint(:cable_assertions, :cable_assertions_color_format,
             check: "color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$'"
           )

    execute(
      """
      CREATE FUNCTION enforce_cable_assertion_immutability() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'cable assertions are immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_cable_assertion_immutability()"
    )

    execute(
      """
      CREATE TRIGGER cable_assertions_enforce_immutability
      BEFORE UPDATE ON cable_assertions
      FOR EACH ROW EXECUTE FUNCTION enforce_cable_assertion_immutability()
      """,
      "DROP TRIGGER cable_assertions_enforce_immutability ON cable_assertions"
    )

    execute(
      """
      CREATE FUNCTION enforce_cable_assertion_retention() RETURNS trigger AS $$
      BEGIN
        -- Organization teardown removes the organization row before cascading,
        -- so only deletes that outlive the organization are allowed. A deleted
        -- source or endpoint would otherwise cascade a confirmed claim away
        -- without a removal event, so retire the cable with retract_cable/2
        -- before deleting one.
        IF NOT EXISTS (SELECT 1 FROM organizations WHERE id = OLD.organization_id) THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'cable assertions are append-only and cannot be deleted while the organization exists'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_cable_assertion_retention()"
    )

    execute(
      """
      CREATE TRIGGER cable_assertions_enforce_retention
      BEFORE DELETE ON cable_assertions
      FOR EACH ROW EXECUTE FUNCTION enforce_cable_assertion_retention()
      """,
      "DROP TRIGGER cable_assertions_enforce_retention ON cable_assertions"
    )

    create table(:cables, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :interface_a_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cables_tenant_a_fkey
          ),
          null: false

      add :interface_b_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cables_tenant_b_fkey
          ),
          null: false

      add :primary_assertion_id,
          references(:cable_assertions,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cables_tenant_assertion_fkey
          ),
          null: false

      add :cable_type, :string
      add :status, :string, null: false, default: "connected"
      add :label, :string
      add :color, :string
      add :length_value, :numeric, precision: 12, scale: 3
      add :length_unit, :string
      add :description, :text
      add :metadata, :map, null: false, default: %{}
      add :last_asserted_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:cables, [:organization_id, :interface_a_id, :interface_b_id],
             name: :cables_endpoints_index
           )

    create unique_index(:cables, [:id, :organization_id])
    create index(:cables, [:organization_id, :interface_a_id], name: :cables_a_index)
    create index(:cables, [:organization_id, :interface_b_id], name: :cables_b_index)

    create constraint(:cables, :cables_canonical_order, check: "interface_a_id < interface_b_id")

    create constraint(:cables, :cables_valid_status,
             check: "status IN ('planned', 'connected', 'decommissioning')"
           )

    create constraint(:cables, :cables_valid_length_unit,
             check: "length_unit IS NULL OR length_unit IN ('m', 'cm', 'ft', 'in')"
           )

    create constraint(:cables, :cables_length_pair,
             check: "(length_value IS NULL) = (length_unit IS NULL)"
           )

    create constraint(:cables, :cables_positive_length,
             check: "length_value IS NULL OR length_value > 0"
           )

    create constraint(:cables, :cables_color_format,
             check: "color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$'"
           )

    create table(:cable_endpoint_terminations, primary_key: false) do
      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false,
        primary_key: true

      add :interface_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_endpoint_terminations_tenant_interface_fkey
          ),
          null: false,
          primary_key: true

      add :cable_id,
          references(:cables,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :cable_endpoint_terminations_tenant_cable_fkey
          ),
          null: false
    end

    create index(:cable_endpoint_terminations, [:cable_id, :organization_id],
             name: :cable_endpoint_terminations_cable_index
           )

    execute(
      """
      CREATE FUNCTION occupy_cable_endpoints() RETURNS trigger AS $$
      BEGIN
        INSERT INTO cable_endpoint_terminations
          (organization_id, interface_id, cable_id)
        VALUES
          (NEW.organization_id, NEW.interface_a_id, NEW.id),
          (NEW.organization_id, NEW.interface_b_id, NEW.id);

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION occupy_cable_endpoints()"
    )

    execute(
      """
      CREATE TRIGGER cables_occupy_endpoints
      AFTER INSERT ON cables
      FOR EACH ROW EXECUTE FUNCTION occupy_cable_endpoints()
      """,
      "DROP TRIGGER cables_occupy_endpoints ON cables"
    )

    execute(
      """
      CREATE FUNCTION enforce_cable_endpoint_termination() RETURNS trigger AS $$
      DECLARE
        checked_cable_id uuid;
        checked_organization_id uuid;
      BEGIN
        IF TG_OP IN ('DELETE', 'UPDATE') THEN
          checked_cable_id := OLD.cable_id;
          checked_organization_id := OLD.organization_id;

          IF EXISTS (
            SELECT 1
            FROM cables cable
            WHERE cable.id = checked_cable_id
              AND cable.organization_id = checked_organization_id
              AND (
                (SELECT count(*)
                 FROM cable_endpoint_terminations termination
                 WHERE termination.cable_id = cable.id
                   AND termination.organization_id = cable.organization_id) <> 2
                OR NOT EXISTS (
                  SELECT 1 FROM cable_endpoint_terminations termination
                  WHERE termination.cable_id = cable.id
                    AND termination.organization_id = cable.organization_id
                    AND termination.interface_id = cable.interface_a_id
                )
                OR NOT EXISTS (
                  SELECT 1 FROM cable_endpoint_terminations termination
                  WHERE termination.cable_id = cable.id
                    AND termination.organization_id = cable.organization_id
                    AND termination.interface_id = cable.interface_b_id
                )
              )
          ) THEN
            RAISE EXCEPTION 'cable endpoint termination is inconsistent'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;

        IF TG_OP IN ('INSERT', 'UPDATE') THEN
          checked_cable_id := NEW.cable_id;
          checked_organization_id := NEW.organization_id;

          IF EXISTS (
            SELECT 1
            FROM cables cable
            WHERE cable.id = checked_cable_id
              AND cable.organization_id = checked_organization_id
              AND (
                (SELECT count(*)
                 FROM cable_endpoint_terminations termination
                 WHERE termination.cable_id = cable.id
                   AND termination.organization_id = cable.organization_id) <> 2
                OR NOT EXISTS (
                  SELECT 1 FROM cable_endpoint_terminations termination
                  WHERE termination.cable_id = cable.id
                    AND termination.organization_id = cable.organization_id
                    AND termination.interface_id = cable.interface_a_id
                )
                OR NOT EXISTS (
                  SELECT 1 FROM cable_endpoint_terminations termination
                  WHERE termination.cable_id = cable.id
                    AND termination.organization_id = cable.organization_id
                    AND termination.interface_id = cable.interface_b_id
                )
              )
          ) THEN
            RAISE EXCEPTION 'cable endpoint termination is inconsistent'
              USING ERRCODE = 'integrity_constraint_violation';
          END IF;
        END IF;

        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_cable_endpoint_termination()"
    )

    execute(
      """
      CREATE CONSTRAINT TRIGGER cable_endpoint_terminations_enforce_consistency
      AFTER INSERT OR UPDATE OR DELETE ON cable_endpoint_terminations
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION enforce_cable_endpoint_termination()
      """,
      "DROP TRIGGER cable_endpoint_terminations_enforce_consistency ON cable_endpoint_terminations"
    )

    execute(
      """
      CREATE FUNCTION enforce_cable_endpoints_immutable() RETURNS trigger AS $$
      BEGIN
        IF NEW.organization_id = OLD.organization_id AND
           NEW.interface_a_id = OLD.interface_a_id AND
           NEW.interface_b_id = OLD.interface_b_id THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'cable endpoints are immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_cable_endpoints_immutable()"
    )

    execute(
      """
      CREATE TRIGGER cables_enforce_endpoints_immutable
      BEFORE UPDATE ON cables
      FOR EACH ROW EXECUTE FUNCTION enforce_cable_endpoints_immutable()
      """,
      "DROP TRIGGER cables_enforce_endpoints_immutable ON cables"
    )

    execute(
      """
      CREATE FUNCTION enforce_cable_primary_assertion() RETURNS trigger AS $$
      DECLARE
        claim record;
      BEGIN
        SELECT kind, action, interface_a_id, interface_b_id
          INTO claim
          FROM cable_assertions
         WHERE id = NEW.primary_assertion_id
           AND organization_id = NEW.organization_id;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'cable primary assertion does not exist in this organization'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        -- The projection boundary is a database invariant, not only a
        -- reconciliation policy: a current cable must be backed by a confirmed
        -- claim for exactly these endpoints, never by a proposal, a retraction,
        -- or a claim about different interfaces.
        IF claim.kind NOT IN ('operator', 'import') OR claim.action <> 'assert' THEN
          RAISE EXCEPTION 'cable primary assertion must be a confirmed cable claim'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        IF claim.interface_a_id <> NEW.interface_a_id OR
           claim.interface_b_id <> NEW.interface_b_id THEN
          RAISE EXCEPTION 'cable endpoints must match its primary assertion'
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION enforce_cable_primary_assertion()"
    )

    execute(
      """
      CREATE TRIGGER cables_enforce_primary_assertion
      BEFORE INSERT OR UPDATE ON cables
      FOR EACH ROW EXECUTE FUNCTION enforce_cable_primary_assertion()
      """,
      "DROP TRIGGER cables_enforce_primary_assertion ON cables"
    )

    create table(:cable_change_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :sequence, :bigserial, null: false

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      # Reconciliation routinely replaces the current cable, so history keeps its
      # cable identity as an opaque reference instead of a cascading foreign key.
      # Endpoint and source references remain tenant-safe and only nullify.
      add :cable_id, :binary_id, null: false

      # The claim that caused this transition: the creating assertion, the
      # newer claim that replaced it, or the retraction/displacing claim that
      # removed the cable. Opaque for the same reason as `cable_id`.
      add :assertion_id, :binary_id

      add :interface_a_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:interface_a_id]},
            type: :binary_id,
            name: :cable_change_events_tenant_a_fkey
          )

      add :interface_b_id,
          references(:interfaces,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:interface_b_id]},
            type: :binary_id,
            name: :cable_change_events_tenant_b_fkey
          )

      add :source_id,
          references(:sources,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:source_id]},
            type: :binary_id,
            name: :cable_change_events_tenant_source_fkey
          )

      add :action, :string, null: false
      add :changes, :map, null: false, default: %{}
      add :snapshot, :map, null: false, default: %{}
      add :occurred_at, :"timestamp(3)", null: false
      add :actor_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create index(:cable_change_events, [:organization_id, :cable_id, :sequence],
             name: :cable_change_events_cable_sequence_index
           )

    create constraint(:cable_change_events, :cable_change_events_valid_action,
             check: "action IN ('created', 'updated', 'removed')"
           )
  end
end
