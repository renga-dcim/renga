defmodule Renga.Repo.Migrations.AddStrictToPrefixes do
  @moduledoc """
  RFD 4, Phase 5: a prefix may opt in to strict address management, where
  every observed address is expected to have a managed record. Observed-only
  addresses stay normal everywhere else, so the policy defaults to off.
  """
  use Ecto.Migration

  def change do
    alter table(:prefixes) do
      add :strict, :boolean, null: false, default: false
    end
  end
end
