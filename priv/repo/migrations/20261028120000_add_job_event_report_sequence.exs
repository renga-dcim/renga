defmodule Renga.Repo.Migrations.AddJobEventReportSequence do
  use Ecto.Migration

  # Agents number their reports within each lease attempt (RFD 9, "Delivery
  # over HTTPS"). Storing that number on the event it produced lets a retried
  # post find its first delivery instead of being recorded twice. Server-made
  # events (leased, lease_lost, ...) have no report sequence.
  def change do
    alter table(:jobs) do
      # The live lease token is cleared when a job finishes. This hash remains
      # for that attempt so the agent can authenticate a retry whose terminal
      # response was lost; lease loss clears it and re-leasing replaces it.
      add :report_token_hash, :binary
    end

    alter table(:job_events) do
      add :report_sequence, :integer
    end

    create constraint(:job_events, :job_events_valid_report_sequence,
             check: "report_sequence IS NULL OR (report_sequence > 0 AND actor_type = 'agent')"
           )

    create unique_index(:job_events, [:job_id, :attempt, :report_sequence],
             where: "report_sequence IS NOT NULL",
             name: :job_events_report_sequence_index
           )
  end
end
