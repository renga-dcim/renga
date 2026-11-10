defmodule RengaWeb.RequestLimit do
  @moduledoc "Authenticated browser HTTP and LiveView admission (RFD 21)."
  import Plug.Conn
  import Phoenix.LiveView

  alias Renga.RequestLimits

  def init(opts), do: opts

  def call(conn, _opts) do
    case RequestLimits.check(conn.assigns[:current_scope], :http) do
      :ok ->
        conn

      {:error, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> send_resp(429, notice(seconds))
        |> halt()
    end
  end

  def on_mount(:default, _params, _session, socket) do
    attribute(socket)

    if connected?(socket) do
      case RequestLimits.check(socket.assigns[:current_scope], :live) do
        :ok ->
          {:cont, attach(socket)}

        {:error, seconds} ->
          rejected(socket)

          {:halt,
           socket
           |> put_flash(:error, notice(seconds))
           |> redirect(to: "/requests/throttled?retry_after=#{seconds}")}
      end
    else
      {:cont, attach(socket)}
    end
  end

  defp attach(socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:request_limit_initial_navigation?, true)
      |> attach_hook(:request_limit, :handle_event, fn _event, _params, socket ->
        admit(socket)
      end)
      |> attach_hook(:request_limit, :handle_params, fn _params, _uri, socket ->
        if socket.assigns.request_limit_initial_navigation? do
          {:cont, Phoenix.Component.assign(socket, :request_limit_initial_navigation?, false)}
        else
          admit(socket)
        end
      end)

    socket
  end

  defp admit(socket) do
    attribute(socket)

    case RequestLimits.check(socket.assigns[:current_scope], :live) do
      :ok ->
        {:cont, socket}

      {:error, seconds} ->
        rejected(socket)
        {:halt, put_flash(socket, :error, notice(seconds))}
    end
  end

  defp attribute(socket) do
    Renga.UsageTelemetry.put_organization(
      get_in(socket.assigns, [:current_scope, Access.key(:organization_id)])
    )
  end

  defp rejected(socket) do
    :telemetry.execute([:renga, :request, :rejected], %{count: 1}, %{
      organization_id: get_in(socket.assigns, [:current_scope, Access.key(:organization_id)]),
      transport: :live,
      status: 429
    })
  end

  defp notice(seconds), do: "Too many requests. Retry in #{seconds} seconds."
end
