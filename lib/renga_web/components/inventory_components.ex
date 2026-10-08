defmodule RengaWeb.InventoryComponents do
  @moduledoc """
  Inventory pieces shared by the resource list and the resource object page,
  so a resource's status reads the same in a row and in its header.
  """
  use Phoenix.Component

  import RengaWeb.UI, only: [status_strip: 1]

  alias RengaWeb.Format

  @doc """
  The four-signal status strip (lifecycle, freshness, agent, drift) for a
  resource with its conditions loaded. Drift comes from `drift_count`.
  """
  attr :resource, :map, required: true
  attr :size, :string, default: "row"
  attr :id, :string, default: nil

  def resource_status(assigns) do
    assigns = assign(assigns, signals(assigns.resource))

    ~H"""
    <.status_strip
      id={@id}
      size={@size}
      lifecycle={@resource.lifecycle_state}
      freshness={@freshness}
      freshness_label={@freshness_label}
      agent={@agent}
      drift={@drift}
    />
    """
  end

  defp signals(resource) do
    freshness = condition_state(resource, "InventoryCurrent", current: true, stale: false)

    %{
      freshness: freshness,
      # A current or stale resource shows how long ago it was seen; one that
      # never reported keeps the plain "Unknown".
      freshness_label: freshness != :unknown && Format.age(resource.last_observed_at),
      agent:
        case condition_state(resource, "AgentConnected", connected: true, lost: false) do
          :unknown -> :none
          state -> state
        end,
      drift: Map.get(resource, :drift_count) || 0
    }
  end

  # Maps a condition's "true"/"false" status onto the two named states, and
  # anything else (missing or "unknown") onto :unknown.
  defp condition_state(resource, type, [{yes, true}, {no, false}]) do
    case Enum.find(resource.conditions, &(&1.type == type)) do
      %{status: "true"} -> yes
      %{status: "false"} -> no
      _other -> :unknown
    end
  end
end
