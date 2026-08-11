defmodule RengaWeb.Plugs.EnrollmentChallengeRateGuard do
  @moduledoc false

  import Plug.Conn

  alias Renga.Enrollment.ChallengeRateLimiter
  alias RengaWeb.TrustedProxySource

  def init(options), do: options

  def call(conn, _options) do
    organization = string_param(conn.body_params, "organization")
    profile = string_param(conn.body_params, "profile")
    trusted_cidrs = Application.get_env(:renga, :enrollment_trusted_proxy_cidrs, [])
    source = TrustedProxySource.resolve(conn, trusted_cidrs)

    if ChallengeRateLimiter.allow?(source, organization, profile) do
      conn
    else
      conn
      |> put_status(:too_many_requests)
      |> Phoenix.Controller.json(%{status: "denied", error: "enrollment_not_available"})
      |> halt()
    end
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end
end
