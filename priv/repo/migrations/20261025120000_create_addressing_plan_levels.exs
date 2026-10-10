defmodule Renga.Repo.Migrations.CreateAddressingPlanLevels do
  @moduledoc """
  RFD 4, Phase 7: an organization's optional addressing plan.

  Each row is one planning level of one address family, such as `/56` per
  hall for IPv6. The levels of a family, ordered by length, decide which
  child length a container's map counts in, instead of a guess from the
  children it happens to have. A family without levels keeps the guess.
  """
  use Ecto.Migration

  def change do
    create table(:addressing_plan_levels, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id, references(:organizations, on_delete: :delete_all, type: :binary_id),
        null: false

      add :family, :string, null: false
      add :prefix_length, :integer, null: false
      add :name, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      timestamps(type: :"timestamp(3)")
    end

    create unique_index(:addressing_plan_levels, [:organization_id, :family, :prefix_length],
             name: :addressing_plan_levels_family_length_index
           )

    # A level is a child length, so neither a whole-space /0 nor a host
    # length plans anything.
    create constraint(:addressing_plan_levels, :addressing_plan_levels_valid_length,
             check:
               "(family = 'ipv4' AND prefix_length BETWEEN 1 AND 31) OR " <>
                 "(family = 'ipv6' AND prefix_length BETWEEN 1 AND 127)"
           )
  end
end
