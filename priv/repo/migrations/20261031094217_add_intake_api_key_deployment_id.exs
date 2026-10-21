defmodule Renga.Repo.Migrations.AddIntakeApiKeyDeploymentId do
  use Ecto.Migration

  # RFD 23: the deployment identifier a key carried when it was issued, if
  # any, so the key list can show which keys still need rotating to gain one.
  # Authentication still hashes the whole key and never reads this column.
  def change do
    alter table(:intake_api_keys) do
      add :deployment_id, :string
    end
  end
end
