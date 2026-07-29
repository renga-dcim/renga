defmodule RengaWeb.PageController do
  use RengaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
