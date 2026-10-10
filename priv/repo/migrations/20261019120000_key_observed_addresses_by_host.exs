defmodule Renga.Repo.Migrations.KeyObservedAddressesByHost do
  @moduledoc """
  RFD 4, Phase 4: observed-address identity becomes interface plus host.

  Until now the same host with two masks on one interface was two observed
  assignments. They merge into one canonical row per interface and host,
  which keeps the most recently observed mask and gains every evidence row of
  the rows it absorbs, so each submitted address and mask stays reported.

  The surviving row is the one still present, then the one with the latest
  evidence, then the shortest mask (the rule ingestion applies to masks
  reported together), so a mask an authoritative report has since withdrawn
  never outlives the one still observed.

  Rollback splits each reported mask that differs from the canonical row
  back into its own withdrawn row and reparents that mask's evidence to it,
  so no evidence is lost on the way down.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE TEMPORARY TABLE address_merges ON COMMIT DROP AS
    WITH candidates AS (
      SELECT address.id,
             address.organization_id,
             address.interface_id,
             host(address.address)::inet AS host,
             (address.metadata -> 'present') IS DISTINCT FROM 'false'::jsonb AS present,
             (SELECT max(evidence.observed_at)
                FROM address_evidence AS evidence
               WHERE evidence.address_id = address.id) AS last_observed_at,
             masklen(address.address) AS mask,
             address.inserted_at
        FROM addresses AS address
    ),
    ranked AS (
      SELECT id,
             first_value(id) OVER (
               PARTITION BY organization_id, interface_id, host
               ORDER BY present DESC, last_observed_at DESC NULLS LAST, mask, inserted_at, id
             ) AS winner_id
        FROM candidates
    )
    SELECT id AS loser_id, winner_id FROM ranked WHERE id <> winner_id
    """

    # Evidence is keyed by observation, canonical address, and reported
    # address; a report two merged rows share would collide, so keep one.
    execute """
    DELETE FROM address_evidence AS evidence
    USING (
      SELECT evidence.id,
             row_number() OVER (
               PARTITION BY COALESCE(merge.winner_id, evidence.address_id),
                            evidence.observation_id,
                            evidence.address
               ORDER BY (merge.loser_id IS NULL) DESC, evidence.inserted_at, evidence.id
             ) AS position
        FROM address_evidence AS evidence
        LEFT JOIN address_merges AS merge ON merge.loser_id = evidence.address_id
       WHERE evidence.address_id IN (
               SELECT loser_id FROM address_merges
               UNION
               SELECT winner_id FROM address_merges
             )
    ) AS ranked
    WHERE evidence.id = ranked.id AND ranked.position > 1
    """

    execute """
    UPDATE address_evidence AS evidence
       SET address_id = merge.winner_id
      FROM address_merges AS merge
     WHERE evidence.address_id = merge.loser_id
    """

    execute """
    DELETE FROM addresses AS address
    USING address_merges AS merge
    WHERE address.id = merge.loser_id
    """

    drop index(:addresses, [:organization_id, :interface_id, :address])

    create unique_index(:addresses, [:organization_id, :interface_id, "(host(address)::inet)"],
             name: :addresses_interface_host_index
           )
  end

  def down do
    drop index(:addresses, [:organization_id, :interface_id, "(host(address)::inet)"],
           name: :addresses_interface_host_index
         )

    execute """
    CREATE TEMPORARY TABLE address_splits ON COMMIT DROP AS
    SELECT DISTINCT ON (evidence.address_id, evidence.address)
           gen_random_uuid() AS id,
           evidence.address_id AS canonical_id,
           evidence.address
      FROM address_evidence AS evidence
      JOIN addresses AS address ON address.id = evidence.address_id
     WHERE evidence.address <> address.address
    """

    execute """
    INSERT INTO addresses
      (id, organization_id, resource_id, interface_id, kind, address, scope, metadata,
       inserted_at, updated_at)
    SELECT split.id, address.organization_id, address.resource_id, address.interface_id,
           address.kind, split.address, address.scope, '{"present": false}'::jsonb,
           address.inserted_at, address.updated_at
      FROM address_splits AS split
      JOIN addresses AS address ON address.id = split.canonical_id
    """

    execute """
    UPDATE address_evidence AS evidence
       SET address_id = split.id
      FROM address_splits AS split
     WHERE evidence.address_id = split.canonical_id AND evidence.address = split.address
    """

    create unique_index(:addresses, [:organization_id, :interface_id, :address])
  end
end
