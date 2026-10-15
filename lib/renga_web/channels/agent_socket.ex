defmodule RengaWeb.AgentSocket do
  @moduledoc """
  The optional socket agents hold open to hear that jobs are waiting (RFD 9,
  "Phoenix Channels notification").

  It authenticates exactly like the HTTPS agent API: the intake key arrives
  as the channels client's auth token (the `Sec-WebSocket-Protocol` header,
  so it stays out of URLs and access logs) and the installation ID in the
  `x-renga-installation-id` header. The socket never delivers job content,
  results or authority. Agents lease over HTTPS whether or not it is open.
  """
  use Phoenix.Socket

  alias RengaWeb.IntakeAuth

  channel "installation:*", RengaWeb.AgentChannel

  @impl true
  def connect(_params, socket, connect_info) do
    installation_header =
      for {"x-renga-installation-id", value} <- Map.get(connect_info, :x_headers, []),
          do: value

    case IntakeAuth.authenticate(connect_info[:auth_token], installation_header) do
      {:ok, scope, installation_id, key} ->
        {:ok,
         socket
         |> assign(:current_scope, scope)
         |> assign(:current_installation_id, installation_id)
         |> assign(:current_intake_api_key, key)}

      :error ->
        :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
