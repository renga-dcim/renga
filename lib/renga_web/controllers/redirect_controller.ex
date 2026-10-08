defmodule RengaWeb.RedirectController do
  @moduledoc """
  Sends retired URLs to their new homes (RFD 8 keeps old routes working as
  redirects while navigation moves to the six areas).

  Each route passes its target as `assigns: %{to: "/places/racks/:id"}`.
  Path parameters in the target are filled from the matched route, and the
  query string is carried over so bookmarked filters keep working. Moves are
  permanent (301) unless the route sets `status: :found` for an area entry
  point whose landing tab may change.
  """
  use RengaWeb, :controller

  def show(conn, _params) do
    %{to: to} = conn.assigns

    location =
      to
      |> String.split("/")
      |> Enum.map_join("/", &fill_segment(&1, conn.path_params))
      |> with_query(conn.query_string)

    conn
    |> put_status(Map.get(conn.assigns, :status, :moved_permanently))
    |> redirect(to: location)
  end

  defp fill_segment(":" <> name, path_params),
    do: URI.encode(Map.fetch!(path_params, name), &URI.char_unreserved?/1)

  defp fill_segment(segment, _path_params), do: segment

  # A target may carry its own query (a retired page that became a filter);
  # the request's query is appended to it.
  defp with_query(path, ""), do: path

  defp with_query(path, query),
    do: path <> if(String.contains?(path, "?"), do: "&", else: "?") <> query
end
