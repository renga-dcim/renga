defmodule Renga.Repo.Migrations.WidenFindingWorkflowResolutionKeys do
  use Ecto.Migration

  # Routing-domain identities include the source UUID and a valid 255-codepoint key.
  def change do
    alter table(:finding_workflows) do
      modify :resolution_key, :text, from: :string
    end
  end
end
