defmodule Renga.SavedViews do
  @moduledoc """
  Saved views for lists (RFD 8): any member saves personal views, and people
  with `views.share` save views shared with the organization. Either kind
  can be pinned to the sidebar; a person's sidebar shows the organization's
  pinned views and their own pinned views.

  Views are scoped to their organization, and a personal view is only ever
  visible to its owner. Opening a view runs the list's normal query under
  the viewer's own scope, so a shared view never reveals data its viewer
  could not otherwise read.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Repo
  alias Renga.SavedViews.SavedView

  @doc "Views on a list visible to the scope: the organization's, then the person's."
  def list_views(%Scope{} = scope, area) do
    scope
    |> visible_query()
    |> where([view], view.area == ^area)
    |> order_by([view], asc: not is_nil(view.user_id), asc: fragment("lower(?)", view.name))
    |> Repo.all()
  end

  @doc "Pinned views for the sidebar: the organization's, then the person's."
  def list_sidebar_views(%Scope{organization_id: nil}), do: []

  def list_sidebar_views(%Scope{} = scope) do
    scope
    |> visible_query()
    |> where([view], view.pinned)
    |> order_by([view], asc: not is_nil(view.user_id), asc: fragment("lower(?)", view.name))
    |> Repo.all()
  end

  @doc "Fetches a view the scope can see; raises otherwise."
  def get_view!(%Scope{} = scope, id), do: scope |> visible_query() |> Repo.get!(id)

  @doc """
  Saves a view. With `shared: true` it is shared with the organization, which
  needs `views.share`; otherwise it belongs to the person saving it.
  """
  def create_view(%Scope{user: %{id: user_id}} = scope, attrs) do
    shared? = attrs |> Map.get(:shared, Map.get(attrs, "shared")) |> truthy?()

    write(scope, shared?, fn ->
      %SavedView{
        organization_id: scope.organization_id,
        user_id: if(shared?, do: nil, else: user_id),
        created_by_id: user_id
      }
      |> SavedView.changeset(attrs)
      |> Repo.insert()
    end)
  end

  def create_view(%Scope{}, _attrs), do: {:error, :forbidden}

  @doc "Renames, re-pins, or replaces the query of a view the scope may manage."
  def update_view(%Scope{} = scope, %SavedView{} = view, attrs) do
    with {:ok, shared?} <- manageable(scope, view) do
      write(scope, shared?, fn -> view |> SavedView.changeset(attrs) |> Repo.update() end)
    end
  end

  @doc "Deletes a view the scope may manage."
  def delete_view(%Scope{} = scope, %SavedView{} = view) do
    with {:ok, shared?} <- manageable(scope, view) do
      write(scope, shared?, fn -> Repo.delete(view) end)
    end
  end

  @doc "Whether the scope may change or delete the view."
  def can_manage?(%Scope{organization_id: org_id}, %SavedView{organization_id: other})
      when org_id != other,
      do: false

  def can_manage?(%Scope{user: %{id: user_id}}, %SavedView{user_id: user_id})
      when is_binary(user_id),
      do: true

  def can_manage?(%Scope{} = scope, %SavedView{user_id: nil}),
    do: Authorization.allowed?(scope, "views.share")

  def can_manage?(%Scope{}, %SavedView{}), do: false

  def change_view(%SavedView{} = view, attrs \\ %{}), do: SavedView.changeset(view, attrs)

  defp visible_query(%Scope{organization_id: organization_id, user: user}) do
    user_id = user && user.id

    SavedView
    |> where([view], view.organization_id == ^organization_id)
    |> where([view], is_nil(view.user_id) or view.user_id == ^user_id)
  end

  # The view must belong to the caller's organization before any permission
  # or ownership check: callers pass structs, not ids, so the struct itself
  # is not proof of access. Returns whether the view is shared.
  defp manageable(%Scope{organization_id: org_id}, %SavedView{organization_id: other})
       when org_id != other,
       do: {:error, :forbidden}

  defp manageable(%Scope{user: %{}}, %SavedView{user_id: nil}), do: {:ok, true}

  defp manageable(%Scope{user: %{id: user_id}}, %SavedView{user_id: user_id})
       when is_binary(user_id),
       do: {:ok, false}

  defp manageable(_scope, _view), do: {:error, :forbidden}

  # Permission and the organization's MFA requirement are re-checked in the
  # database inside the write's transaction. Personal views need only the
  # baseline inventory access their owner already uses to open them.
  defp write(%Scope{} = scope, shared?, write) do
    Repo.transaction(fn ->
      permission = if shared?, do: "views.share", else: "inventory.read"
      Authorization.authorize!(scope, permission)

      case write.() do
        {:ok, view} -> view
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp truthy?(value), do: value in [true, "true", "on"]
end
