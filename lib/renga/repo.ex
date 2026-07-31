defmodule Renga.Repo do
  @moduledoc """
  Database boundary for Renga's single PostgreSQL-backed tenancy model.
  """

  use Ecto.Repo,
    otp_app: :renga,
    adapter: Ecto.Adapters.Postgres
end
