defmodule RengaWeb.AppearanceHook do
  @moduledoc """
  Keeps a signed-in person's theme, accent, and density in step between
  the server and the page (RFD 8, "Visual design").

  The root layout renders the stored preferences onto `<html>`, so pages
  never flash the wrong theme. When preferences change during a session,
  `push_appearance/1` sends them to `assets/js/app.js`, which updates the
  attributes in place. The sidebar's theme button sends `cycle_theme`,
  handled here for every LiveView so the choice is saved, not just shown.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  alias Renga.Accounts
  alias Renga.Accounts.Appearance

  @next_theme %{"system" => "light", "light" => "dark", "dark" => "system"}

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :appearance, :handle_event, &handle_event/3)}
  end

  defp handle_event("cycle_theme", _params, socket) do
    case socket.assigns[:current_scope] do
      %{user: %{} = user} = scope ->
        case Accounts.update_user_appearance(user, %{
               theme: Map.get(@next_theme, user.theme, "system")
             }) do
          {:ok, user} ->
            {:halt,
             socket
             |> assign(:current_scope, %{scope | user: user})
             |> push_appearance()}

          {:error, _changeset} ->
            {:halt, socket}
        end

      _signed_out ->
        {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @doc "Sends the socket's appearance to the page, which applies it in place."
  def push_appearance(socket) do
    appearance = Appearance.for_scope(socket.assigns.current_scope)
    push_event(socket, "appearance", Map.from_struct(appearance))
  end
end
