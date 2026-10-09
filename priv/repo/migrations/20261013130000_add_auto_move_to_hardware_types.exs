defmodule Renga.Repo.Migrations.AddAutoMoveToHardwareTypes do
  @moduledoc """
  A hardware type can move resources to its latest revision on its own once
  they fit it (RFD 8, "Editing hardware components"). Off by default.
  """
  use Ecto.Migration

  def change do
    alter table(:hardware_types) do
      add :auto_move, :boolean, null: false, default: false
    end
  end
end
