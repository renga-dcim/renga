defmodule Renga.Repo do
  use Ecto.Repo,
    otp_app: :renga,
    adapter: Ecto.Adapters.Postgres
end
