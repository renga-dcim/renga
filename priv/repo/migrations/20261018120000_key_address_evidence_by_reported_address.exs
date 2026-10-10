defmodule Renga.Repo.Migrations.KeyAddressEvidenceByReportedAddress do
  @moduledoc """
  RFD 4, Phase 4: address evidence is keyed by the reported address as well
  as the observation and canonical address.

  Observed-address identity is about to become interface plus host, so one
  canonical address can receive `192.0.2.10/24` and `192.0.2.10/32` from the
  same observation. Each submitted mask is evidence the RFD keeps, so the
  per-observation link must allow one row per reported `inet`, while still
  making a replayed observation idempotent. This runs before any evidence is
  reparented onto merged addresses.
  """
  use Ecto.Migration

  def up do
    drop index(:address_evidence, [:organization_id, :observation_id, :address_id],
           name: :address_evidence_observation_link_index
         )

    create unique_index(
             :address_evidence,
             [:organization_id, :observation_id, :address_id, :address],
             name: :address_evidence_observation_link_index
           )
  end

  def down do
    # The narrower link holds one report per observation and address: keep
    # the one matching the canonical mask, otherwise the earliest stored.
    execute """
    DELETE FROM address_evidence AS evidence
    USING (
      SELECT evidence.id,
             row_number() OVER (
               PARTITION BY evidence.organization_id, evidence.observation_id, evidence.address_id
               ORDER BY (evidence.address = address.address) DESC, evidence.inserted_at, evidence.id
             ) AS position
      FROM address_evidence AS evidence
      JOIN addresses AS address ON address.id = evidence.address_id
    ) AS ranked
    WHERE evidence.id = ranked.id AND ranked.position > 1
    """

    drop index(:address_evidence, [:organization_id, :observation_id, :address_id, :address],
           name: :address_evidence_observation_link_index
         )

    create unique_index(:address_evidence, [:organization_id, :observation_id, :address_id],
             name: :address_evidence_observation_link_index
           )
  end
end
