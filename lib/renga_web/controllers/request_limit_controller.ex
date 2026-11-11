defmodule RengaWeb.RequestLimitController do
  use RengaWeb, :controller

  # A rejected connected mount has no page assigns to render. Redirect it
  # here rather than letting a partially initialized LiveView crash or loop.
  def show(conn, params) do
    seconds =
      case Integer.parse(params["retry_after"] || "60") do
        {seconds, ""} when seconds in 1..60 -> seconds
        _invalid -> 60
      end

    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(429)
    |> text("Too many requests. Go back and retry in #{seconds} seconds.")
  end
end
