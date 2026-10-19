defmodule RengaWeb.StaticFontsTest do
  use RengaWeb.ConnCase, async: true

  test "serves the design system's bundled fonts", %{conn: conn} do
    conn = get(conn, "/fonts/ibm-plex-sans-latin-400-normal.woff2")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["font/woff2"]
  end
end
