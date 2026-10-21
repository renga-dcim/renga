defmodule Renga.Repo.Migrations.AddPowerCableKind do
  use Ecto.Migration

  # RFD 10 phase 2: power connections reuse RFD 7's plan, assertion, and
  # current-cable model with a `power` cable kind. A data cable joins two
  # interfaces; a power cable joins a power port (side a) to an outlet or a
  # feed (side b). A port only ever sits on side a and outlets and feeds only
  # on side b, so plain partial unique indexes keep each power endpoint on at
  # most one current cable; the interface termination table stays data-only.
  @tables ~w(cable_plans cable_assertions cables)a

  def up do
    # Cable history pins an endpoint (assertions are append-only), so one the
    # hardware type no longer defines is retired instead of deleted.
    for table <- [:power_ports, :power_outlets] do
      alter table(table) do
        add :retired_at, :"timestamp(3)"
      end
    end

    for table <- @tables do
      alter table(table) do
        add :cable_kind, :string, null: false, default: "data"

        add :power_port_id,
            references(:power_ports,
              with: [organization_id: :organization_id],
              on_delete: :delete_all,
              type: :binary_id,
              name: :"#{table}_tenant_power_port_fkey"
            )

        add :power_outlet_id,
            references(:power_outlets,
              with: [organization_id: :organization_id],
              on_delete: :delete_all,
              type: :binary_id,
              name: :"#{table}_tenant_power_outlet_fkey"
            )

        add :power_feed_id,
            references(:power_feeds,
              with: [organization_id: :organization_id],
              on_delete: :delete_all,
              type: :binary_id,
              name: :"#{table}_tenant_power_feed_fkey"
            )

        modify :interface_a_id, :binary_id, null: true, from: {:binary_id, null: false}
        modify :interface_b_id, :binary_id, null: true, from: {:binary_id, null: false}
      end

      create constraint(table, :"#{table}_endpoint_shape", check: endpoint_shape())
    end

    # Evidence only ever proposes data cables.
    create constraint(:cable_assertions, :cable_assertions_evidence_is_data,
             check: "kind <> 'neighbor_evidence' OR cable_kind = 'data'"
           )

    create unique_index(:cable_plans, [:organization_id, :power_port_id, :power_outlet_id],
             where: "power_outlet_id IS NOT NULL",
             name: :cable_plans_power_outlet_pair_index
           )

    create unique_index(:cable_plans, [:organization_id, :power_port_id, :power_feed_id],
             where: "power_feed_id IS NOT NULL",
             name: :cable_plans_power_feed_pair_index
           )

    for {column, name} <- [
          power_port_id: :cables_power_port_index,
          power_outlet_id: :cables_power_outlet_index,
          power_feed_id: :cables_power_feed_index
        ] do
      create unique_index(:cables, [:organization_id, column],
               where: "#{column} IS NOT NULL",
               name: name
             )
    end

    create index(:cable_assertions, [:organization_id, :power_port_id],
             where: "power_port_id IS NOT NULL"
           )

    alter table(:cable_change_events) do
      add :cable_kind, :string, null: false, default: "data"
      # Opaque like `cable_id`: history outlives the endpoints.
      add :power_port_id, :binary_id
      add :power_outlet_id, :binary_id
      add :power_feed_id, :binary_id
    end

    execute("""
    CREATE OR REPLACE FUNCTION occupy_cable_endpoints() RETURNS trigger AS $$
    BEGIN
      -- Power endpoints are held by the partial unique indexes on cables.
      IF NEW.cable_kind = 'power' THEN
        RETURN NEW;
      END IF;

      INSERT INTO cable_endpoint_terminations
        (organization_id, interface_id, cable_id)
      VALUES
        (NEW.organization_id, NEW.interface_a_id, NEW.id),
        (NEW.organization_id, NEW.interface_b_id, NEW.id);

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_cable_endpoints_immutable() RETURNS trigger AS $$
    BEGIN
      IF NEW.organization_id = OLD.organization_id AND
         NEW.cable_kind = OLD.cable_kind AND
         NEW.interface_a_id IS NOT DISTINCT FROM OLD.interface_a_id AND
         NEW.interface_b_id IS NOT DISTINCT FROM OLD.interface_b_id AND
         NEW.power_port_id IS NOT DISTINCT FROM OLD.power_port_id AND
         NEW.power_outlet_id IS NOT DISTINCT FROM OLD.power_outlet_id AND
         NEW.power_feed_id IS NOT DISTINCT FROM OLD.power_feed_id THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'cable endpoints are immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_cable_primary_assertion() RETURNS trigger AS $$
    DECLARE
      claim record;
    BEGIN
      SELECT kind, action, cable_kind, interface_a_id, interface_b_id,
             power_port_id, power_outlet_id, power_feed_id
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
      -- or a claim about different endpoints.
      IF claim.kind NOT IN ('operator', 'import') OR claim.action <> 'assert' THEN
        RAISE EXCEPTION 'cable primary assertion must be a confirmed cable claim'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      IF claim.cable_kind IS DISTINCT FROM NEW.cable_kind OR
         claim.interface_a_id IS DISTINCT FROM NEW.interface_a_id OR
         claim.interface_b_id IS DISTINCT FROM NEW.interface_b_id OR
         claim.power_port_id IS DISTINCT FROM NEW.power_port_id OR
         claim.power_outlet_id IS DISTINCT FROM NEW.power_outlet_id OR
         claim.power_feed_id IS DISTINCT FROM NEW.power_feed_id THEN
        RAISE EXCEPTION 'cable endpoints must match its primary assertion'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)
  end

  def down do
    execute("DELETE FROM cables WHERE cable_kind = 'power'")
    execute("DELETE FROM cable_plans WHERE cable_kind = 'power'")

    raise_if_power_assertions =
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM cable_assertions WHERE cable_kind = 'power') " <>
        "THEN RAISE EXCEPTION 'power cable assertions are append-only history'; END IF; END $$"

    execute(raise_if_power_assertions)

    execute("""
    CREATE OR REPLACE FUNCTION occupy_cable_endpoints() RETURNS trigger AS $$
    BEGIN
      INSERT INTO cable_endpoint_terminations
        (organization_id, interface_id, cable_id)
      VALUES
        (NEW.organization_id, NEW.interface_a_id, NEW.id),
        (NEW.organization_id, NEW.interface_b_id, NEW.id);

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_cable_endpoints_immutable() RETURNS trigger AS $$
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
    """)

    execute("""
    CREATE OR REPLACE FUNCTION enforce_cable_primary_assertion() RETURNS trigger AS $$
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
    """)

    alter table(:cable_change_events) do
      remove :cable_kind
      remove :power_port_id
      remove :power_outlet_id
      remove :power_feed_id
    end

    drop_if_exists index(:cable_assertions, [:organization_id, :power_port_id])
    drop index(:cables, [], name: :cables_power_feed_index)
    drop index(:cables, [], name: :cables_power_outlet_index)
    drop index(:cables, [], name: :cables_power_port_index)
    drop index(:cable_plans, [], name: :cable_plans_power_feed_pair_index)
    drop index(:cable_plans, [], name: :cable_plans_power_outlet_pair_index)
    drop constraint(:cable_assertions, :cable_assertions_evidence_is_data)

    for table <- [:power_ports, :power_outlets] do
      alter table(table) do
        remove :retired_at
      end
    end

    for table <- @tables do
      drop constraint(table, :"#{table}_endpoint_shape")

      alter table(table) do
        modify :interface_a_id, :binary_id, null: false, from: {:binary_id, null: true}
        modify :interface_b_id, :binary_id, null: false, from: {:binary_id, null: true}
        remove :power_feed_id
        remove :power_outlet_id
        remove :power_port_id
        remove :cable_kind
      end
    end
  end

  defp endpoint_shape do
    """
    (cable_kind = 'data'
     AND interface_a_id IS NOT NULL AND interface_b_id IS NOT NULL
     AND power_port_id IS NULL AND power_outlet_id IS NULL AND power_feed_id IS NULL)
    OR (cable_kind = 'power'
        AND interface_a_id IS NULL AND interface_b_id IS NULL
        AND power_port_id IS NOT NULL
        AND num_nonnulls(power_outlet_id, power_feed_id) = 1)
    """
  end
end
