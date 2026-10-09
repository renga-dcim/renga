defmodule Renga.Requests.Request do
  @moduledoc """
  A change a member proposed but may not apply: a resource's lifecycle, an
  override of one host field, its owning team, or the hardware it expects. Values are stored as
  `%{"value" => ...}` so the record reads the same whatever the field type.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @kinds ~w(lifecycle field_override owner expectation)
  @statuses ~w(open approved rejected withdrawn)

  schema "change_requests" do
    field :kind, :string
    field :field, :string, default: ""
    field :before_value, :map
    field :after_value, :map
    field :reason, :string
    field :status, :string, default: "open"
    field :decided_at, :utc_datetime_usec
    field :decision_note, :string

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :requested_by_user, User
    belongs_to :decided_by_user, User

    timestamps()
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc """
  A new request. `kind`, `field`, and the before value are set by the
  context from the resource, never from attrs; attrs carry only the
  proposed value and the reason.
  """
  def create_changeset(request, attrs) do
    request
    |> cast(attrs, [:reason])
    |> put_after_value(attrs)
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:reason], message: "say why this change is needed")
    |> validate_length(:reason, max: 500)
    |> validate_required([:organization_id, :resource_id, :kind, :after_value])
    |> validate_inclusion(:kind, @kinds)
    |> validate_changed()
    |> unique_constraint([:organization_id, :resource_id, :kind, :field],
      name: :change_requests_open_change_index,
      message: "already has an open request"
    )
  end

  @doc "Closes the request as approved, rejected, or withdrawn."
  def decide_changeset(request, status, decided_by_user_id, note, now)
      when status in ~w(approved rejected withdrawn) do
    request
    |> change(
      status: status,
      decided_by_user_id: decided_by_user_id,
      decided_at: now,
      decision_note: note |> to_string() |> String.trim() |> blank_to_nil()
    )
    |> validate_length(:decision_note, max: 500)
  end

  defp put_after_value(changeset, attrs) do
    case attrs |> Map.get("value") |> normalize() do
      nil -> changeset
      value -> put_change(changeset, :after_value, %{"value" => value})
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp normalize(_value), do: nil

  defp validate_changed(changeset) do
    # Pinning an observed value changes its ownership even if its text stays the same.
    after_value = changeset |> get_field(:after_value) |> plain_value()

    if get_field(changeset, :kind) in ["lifecycle", "owner"] and not is_nil(after_value) and
         after_value == changeset |> get_field(:before_value) |> plain_value() do
      add_error(changeset, :after_value, "is already the current value")
    else
      changeset
    end
  end

  defp plain_value(%{"value" => value}), do: value
  defp plain_value(_missing), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
