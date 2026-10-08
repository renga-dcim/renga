defmodule Renga.Repo.Migrations.AddIntakeSignalsToObservations do
  @moduledoc """
  Where each collector report came from (RFD 8, "Triage": the network
  location rule matches the reporting subnet or intake key).

  `reported_from` is the address the intake request arrived from, as the
  endpoint sees it, and `intake_api_key_id` the key it authenticated with.
  Both are recorded by the server at intake and are never taken from the
  payload. Reports from other paths leave them empty.
  """

  use Ecto.Migration

  def change do
    create unique_index(:intake_api_keys, [:id, :organization_id])

    alter table(:observations) do
      add :reported_from, :inet

      add :intake_api_key_id,
          references(:intake_api_keys,
            with: [organization_id: :organization_id],
            on_delete: {:nilify, [:intake_api_key_id]},
            type: :binary_id,
            name: :observations_intake_api_key_fkey
          )
    end

    create index(:observations, [:organization_id, :intake_api_key_id])
  end
end
