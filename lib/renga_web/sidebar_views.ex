defmodule RengaWeb.SidebarViews do
  @moduledoc """
  Loads the signed-in person's pinned views for the sidebar once per page
  mount, as `@sidebar_views`. Pages pass it to `Layouts.app`; loading it in
  the layout itself would re-query on every render.

  A page that changes views (such as Inventory saving or pinning one)
  reassigns it with `refresh/1` so its own sidebar stays current.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Renga.SavedViews

  def on_mount(:default, _params, _session, socket) do
    {:cont, refresh(socket)}
  end

  @doc "Re-reads the sidebar views for the socket's scope."
  def refresh(socket) do
    views =
      case socket.assigns[:current_scope] do
        %{organization_id: organization_id} = scope when is_binary(organization_id) ->
          SavedViews.list_sidebar_views(scope)

        _no_organization ->
          []
      end

    assign(socket, :sidebar_views, views)
  end
end
