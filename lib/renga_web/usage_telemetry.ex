defmodule RengaWeb.UsageTelemetry do
  @moduledoc "Organization attribution for browser requests and rejected HTTP work."
  import Plug.Conn
  alias Renga.UsageTelemetry

  def init(mode), do: mode

  def call(conn, :start) do
    UsageTelemetry.put_organization(nil)

    register_before_send(conn, fn conn ->
      organization_id = get_in(conn.assigns, [:current_scope, Access.key(:organization_id)])
      metadata = %{organization_id: organization_id, transport: :http, status: conn.status}

      if conn.status >= 400 and not match?(["api", "v1" | _], conn.path_info),
        do: :telemetry.execute([:renga, :request, :rejected], %{count: 1}, metadata)

      UsageTelemetry.put_organization(nil)
      conn
    end)
  end

  def call(conn, :scope) do
    UsageTelemetry.put_organization(
      get_in(conn.assigns, [:current_scope, Access.key(:organization_id)])
    )

    conn
  end
end
