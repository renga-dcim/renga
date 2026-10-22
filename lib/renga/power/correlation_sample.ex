defmodule Renga.Power.CorrelationSample do
  @moduledoc """
  One minute of one outlet or supply-input series in the correlation window
  (RFD 10, "Suggested connections"), kept by `Renga.Power.Correlation`. Only
  valid samples are kept, so a failed read is a gap and never zero.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "power_correlation_samples" do
    field :target, :string
    field :sensor, :string
    field :boundary, :string
    field :quantity, :string
    field :component_kind, :string
    field :component_name, :string
    field :minute, :utc_datetime
    field :event_at, :utc_datetime_usec
    field :value, :decimal
    field :state, :string

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :source, Renga.Inventory.Source
  end
end
