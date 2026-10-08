defmodule Renga.Findings.Workflow do
  @moduledoc """
  The judgment people add to one finding identity: who is looking at it,
  until when it is snoozed, and whether it is accepted as an exception.

  Reconciliation alone opens and closes findings; nothing here can resolve
  one. The row is keyed by identity rather than finding id because every
  finding domain inserts a new finding row when a resolved finding recurs,
  and an accepted exception or an assignee should survive that.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization
  alias Renga.Accounts.User
  alias Renga.Inventory.Resource

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  @domains ~w(component hardware_match placement topology)
  @reason_max 500

  schema "finding_workflows" do
    field :domain, :string
    field :subject_id, :binary_id
    field :kind, :string
    field :resolution_key, :string, default: ""
    field :snoozed_until, :utc_datetime_usec
    field :exception_reason, :string
    field :exception_expires_at, :utc_datetime_usec
    field :exception_at, :utc_datetime_usec

    belongs_to :organization, Organization
    belongs_to :resource, Resource
    belongs_to :assignee_user, User
    belongs_to :exception_by_user, User

    timestamps()
  end

  def domains, do: @domains

  @doc "Sets or clears the assignee. The caller checks the assignee is a member."
  def assign_changeset(workflow, assignee_user_id),
    do: change(workflow, assignee_user_id: assignee_user_id)

  @doc "Snoozes until a future time, or wakes the finding with nil."
  def snooze_changeset(workflow, until, now) do
    workflow
    |> change(snoozed_until: until)
    |> validate_future(:snoozed_until, now)
  end

  @doc """
  Accepts the finding as an exception. A reason is required so everyone who
  later sees the resource knows why; the expiry is optional.
  """
  def exception_changeset(workflow, attrs, actor_id, now) do
    workflow
    |> cast(attrs, [:exception_reason, :exception_expires_at])
    |> update_change(:exception_reason, &String.trim/1)
    |> validate_required([:exception_reason], message: "explain why this is acceptable")
    |> validate_length(:exception_reason, max: @reason_max)
    |> validate_future(:exception_expires_at, now)
    |> put_change(:exception_at, now)
    |> put_change(:exception_by_user_id, actor_id)
  end

  @doc "Removes an accepted exception, returning the finding to the queue."
  def remove_exception_changeset(workflow) do
    change(workflow,
      exception_reason: nil,
      exception_expires_at: nil,
      exception_at: nil,
      exception_by_user_id: nil
    )
  end

  @doc "True while an exception is accepted and not yet expired."
  def excepted?(%__MODULE__{exception_at: nil}, _now), do: false
  def excepted?(%__MODULE__{exception_expires_at: nil}, _now), do: true

  def excepted?(%__MODULE__{exception_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  def excepted?(nil, _now), do: false

  @doc "True while snoozed until a time still in the future."
  def snoozed?(%__MODULE__{snoozed_until: %DateTime{} = until}, now),
    do: DateTime.compare(until, now) == :gt

  def snoozed?(_workflow, _now), do: false

  defp validate_future(changeset, field, now) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value ->
        if DateTime.compare(value, now) == :gt,
          do: changeset,
          else: add_error(changeset, field, "must be in the future")
    end
  end
end
