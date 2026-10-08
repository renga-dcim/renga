defmodule RengaWeb.InventoryComponents do
  @moduledoc """
  Inventory pieces shared by the resource list and the resource object page,
  so a resource's status reads the same in a row and in its header.
  """
  use RengaWeb, :html

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

  @doc """
  The frame every resource tab shares (RFD 8, "Object pages"): breadcrumb,
  title, status strip, and the domain tabs. Tabs within the resource page
  patch; the Hardware tab, a separate page, navigates.

  The Hardware tab only exists for physical device kinds; the command menu
  explains its absence on other kinds.
  """
  attr :resource, :map, required: true
  attr :tab, :atom, required: true, values: [:overview, :hardware, :network, :sources, :activity]
  attr :hardware?, :boolean, required: true
  slot :inner_block, required: true
  slot :aside

  def resource_frame(assigns) do
    resource = assigns.resource

    assigns =
      assign(assigns,
        tabs:
          [
            {:overview, "Overview", ~p"/inventory/#{resource}", nil},
            assigns.hardware? &&
              {:hardware, "Hardware", ~p"/inventory/#{resource}/hardware",
               nonzero(resource.drift_count)},
            {:network, "Network", ~p"/inventory/#{resource}/network",
             nonzero(length(resource.interfaces))},
            {:sources, "Sources", ~p"/inventory/#{resource}/sources",
             nonzero(length(resource.source_names))},
            {:activity, "Activity", ~p"/inventory/#{resource}/activity", nil}
          ]
          |> Enum.filter(& &1)
      )

    ~H"""
    <.object_page
      id="resource-detail"
      title={@resource.display_name || @resource.name}
      subtitle={subtitle(@resource)}
    >
      <:breadcrumb>
        <.link navigate={~p"/inventory"} class="hover:text-fg">Inventory</.link>
        <span aria-hidden="true">/</span>
        <span class="text-fg">{@resource.name}</span>
      </:breadcrumb>
      <:icon><.icon name={kind_icon(@resource.kind)} class="size-5" /></:icon>
      <:status><.resource_status id="resource-status" resource={@resource} size="header" /></:status>
      <:tab
        :for={{id, label, path, count} <- @tabs}
        patch={if(id != :hardware and @tab != :hardware, do: path)}
        navigate={if(id == :hardware or @tab == :hardware, do: path)}
        active={id == @tab}
        count={count}
      >
        {label}
      </:tab>
      {render_slot(@inner_block)}
      <:aside :if={@aside != []}>{render_slot(@aside)}</:aside>
    </.object_page>
    """
  end

  defp subtitle(resource) do
    if resource.display_name && resource.display_name != resource.name,
      do: "#{resource.name} · #{Format.humanize(resource.kind)}",
      else: Format.humanize(resource.kind)
  end

  defp nonzero(0), do: nil
  defp nonzero(count), do: count

  @doc "The icon name for a resource kind."
  def kind_icon(kind) when kind in ~w(server storage), do: "hero-server-stack"
  def kind_icon("switch"), do: "hero-arrows-right-left"
  def kind_icon("pdu"), do: "hero-bolt"
  def kind_icon(kind) when kind in ~w(vm container), do: "hero-square-3-stack-3d"
  def kind_icon(_kind), do: "hero-cube"
end
