defmodule Renga.Repo.Migrations.CreateChangeRequests do
  @moduledoc """
  Member requests (RFD 8, "Inbox"): a permanent change a member proposed
  but may not apply directly, waiting for an owner or admin.

  A request records the proposer, their reason, and the value before and
  after, so an approver sees the effect of approving. Approval applies the
  change as the approver; the request keeps the requester. At most one
  request is open per change on a resource (its lifecycle, or one host
  field), so a second proposer finds the open one instead of a duplicate.
  """

  use Ecto.Migration

  def change do
    create table(:change_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false

      add :resource_id,
          references(:resources,
            with: [organization_id: :organization_id],
            on_delete: :delete_all,
            type: :binary_id,
            name: :change_requests_resource_fkey
          ),
          null: false

      add :kind, :string, null: false
      add :field, :string, null: false, default: ""
      add :before_value, :map
      add :after_value, :map, null: false
      add :reason, :text, null: false
      add :status, :string, null: false, default: "open"
      add :requested_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :decided_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :decided_at, :utc_datetime_usec
      add :decision_note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:change_requests, [:organization_id, :resource_id, :kind, :field],
             where: "status = 'open'",
             name: :change_requests_open_change_index
           )

    create index(:change_requests, [:organization_id, :status, :inserted_at])
    create index(:change_requests, [:organization_id, :kind, :field, :status])

    create constraint(:change_requests, :change_requests_valid_kind,
             check: "kind IN ('lifecycle', 'field_override')"
           )

    create constraint(:change_requests, :change_requests_valid_status,
             check: "status IN ('open', 'approved', 'rejected', 'withdrawn')"
           )

    create constraint(:change_requests, :change_requests_decision_state,
             check: """
             (status = 'open' AND decided_at IS NULL) OR
               (status <> 'open' AND decided_at IS NOT NULL)
             """
           )
  end
end
