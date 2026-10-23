defmodule RengaWeb.AccessHook do
  @moduledoc """
  Keeps a connected page's organization access current (RFD 16,
  "Authorization changes"). When a person's grant in the page's
  organization changes, the page re-reads it at once instead of serving
  data under the access it mounted with: a page whose person lost the
  organization goes to organization selection, and any other reloads with
  the new scope. Pages in other organizations are untouched.
  """

  import Phoenix.LiveView

  alias Renga.Accounts
  alias Renga.Accounts.Scope
  alias Renga.Scim.Grants

  use RengaWeb, :verified_routes

  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_scope] do
      %Scope{organization_id: organization_id, user: %{id: user_id}}
      when is_binary(organization_id) ->
        if connected?(socket) do
          Grants.subscribe(organization_id, user_id)
          # A change that committed between reading the scope and
          # subscribing was announced to nobody, so read it again now that
          # later ones will arrive.
          with_current_access(socket, organization_id, &{:cont, attach(&1)})
        else
          {:cont, attach(socket)}
        end

      _no_organization ->
        {:cont, socket}
    end
  end

  defp remember_path(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)

    {:cont,
     Phoenix.Component.assign(socket, :access_path, if(query, do: "#{path}?#{query}", else: path))}
  end

  defp attach(socket) do
    socket
    |> attach_hook(:access_path, :handle_params, &remember_path/3)
    |> attach_hook(:access_changed, :handle_info, &access_changed/2)
  end

  defp access_changed({:access_changed, organization_id}, socket) do
    with_current_access(socket, organization_id, fn socket ->
      {:halt, redirect(socket, to: socket.assigns[:access_path] || ~p"/organizations")}
    end)
  end

  defp access_changed(_message, socket), do: {:cont, socket}

  # Re-reads the person's access in the organization: `kept` gets the
  # socket with it, and a person who lost the organization goes to
  # organization selection.
  defp with_current_access(socket, organization_id, kept) do
    %Scope{user: user} = socket.assigns.current_scope

    case Accounts.scope_for_user(user, organization_id) do
      %Scope{organization_id: ^organization_id} = scope ->
        socket |> Phoenix.Component.assign(:current_scope, scope) |> kept.()

      _lost ->
        {:halt,
         socket
         |> put_flash(:error, "You no longer have access to that organization.")
         |> redirect(to: ~p"/organizations")}
    end
  end
end
