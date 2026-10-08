defmodule Renga.SavedViews.SavedView do
  @moduledoc """
  A named list query. Personal when `user_id` is set, shared with the whole
  organization when it is nil. `params` is the list's URL query, so a view
  is opened by visiting the list with it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @areas ~w(inventory)
  @max_params 20
  @max_param_length 2_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "saved_views" do
    field :area, :string
    field :name, :string
    field :params, :map, default: %{}
    field :pinned, :boolean, default: false

    belongs_to :organization, Renga.Accounts.Organization
    belongs_to :user, Renga.Accounts.User
    belongs_to :created_by, Renga.Accounts.User

    timestamps()
  end

  def areas, do: @areas

  @doc "Whether the view is shared with the whole organization."
  def shared?(%__MODULE__{user_id: nil}), do: true
  def shared?(%__MODULE__{}), do: false

  @doc """
  Casts what a person may change. Ownership (`organization_id`, `user_id`,
  `created_by_id`) is set by the context from the scope, never from params.
  """
  def changeset(view, attrs) do
    view
    |> cast(attrs, [:area, :name, :params, :pinned])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:area, :name])
    |> validate_length(:name, max: 60)
    |> validate_inclusion(:area, @areas)
    |> validate_change(:params, &validate_params/2)
    |> unique_constraint(:name,
      name: :saved_views_personal_name_index,
      message: "you already have a view with this name"
    )
    |> unique_constraint(:name,
      name: :saved_views_organization_name_index,
      message: "the organization already has a view with this name"
    )
  end

  # Views hold a URL query: a small map of strings to strings.
  defp validate_params(:params, params) do
    valid? =
      map_size(params) <= @max_params and
        Enum.all?(params, fn {key, value} ->
          is_binary(key) and is_binary(value) and String.length(value) <= @max_param_length
        end)

    if valid?, do: [], else: [params: "must be a short list query"]
  end
end
