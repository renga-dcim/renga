defmodule Renga.Repo.Migrations.CreateOperatorIdempotencyKeys do
  use Ecto.Migration

  # RFD 22, "Writes": the completed response to each non-idempotent operator
  # request, keyed by the token, method, route, and the caller's
  # Idempotency-Key, so a retry returns the same result instead of acting
  # again. Only a digest of the request is kept, never its body.
  def change do
    create table(:operator_idempotency_keys) do
      add :operator_token_id,
          references(:operator_tokens, type: :binary_id, on_delete: :delete_all),
          null: false

      add :method, :string, null: false
      add :route, :string, null: false
      add :key, :string, null: false
      add :request_digest, :binary, null: false
      add :response_status, :integer, null: false
      add :response_body, :map, null: false
      add :expires_at, :"timestamp(3)", null: false

      timestamps(type: :"timestamp(3)", updated_at: false)
    end

    create unique_index(:operator_idempotency_keys, [:operator_token_id, :method, :route, :key],
             name: :operator_idempotency_keys_namespace_index
           )

    create index(:operator_idempotency_keys, [:expires_at])
  end
end
