defmodule RengaWeb.Navigation do
  @moduledoc """
  The one navigation definition (RFD 8). The sidebar, the mobile menu, the
  command menu, and each area's tabs are all generated from it, so they cannot
  drift apart.

  The six areas answer the operator's questions and do not grow per feature:
  new pages become sections (tabs) of an existing area. Settings sits outside
  the six and holds organization and personal configuration.

  Pages declare where they are with `active_nav`, a section id such as
  `:vlans`; the layout finds the section's area from here.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: RengaWeb.Endpoint,
    router: RengaWeb.Router,
    statics: RengaWeb.static_paths()

  # Areas are maps of :id, :label, :question (the RFD 8 question it answers),
  # :icon, and :sections. Sections are maps of :id, :label, :path, :icon, and
  # :keywords, which the command menu also matches on.

  @doc "The six top-level areas, in sidebar order."
  def areas do
    [
      %{
        id: :inbox,
        label: "Inbox",
        question: "What needs me?",
        icon: "hero-inbox",
        sections: [
          section(:inbox, "Queue", ~p"/inbox", "hero-inbox",
            keywords: ~w(findings drift health hardware vlan neighbor cabling rack placement)
          )
        ]
      },
      %{
        id: :inventory,
        label: "Inventory",
        question: "What exists?",
        icon: "hero-cube",
        sections: [
          section(:inventory, "Resources", ~p"/inventory", "hero-cube",
            keywords: ~w(servers devices hosts)
          )
        ]
      },
      %{
        id: :places,
        label: "Places",
        question: "Where is it?",
        icon: "hero-building-office-2",
        sections: [
          section(:sites, "Sites", ~p"/places", "hero-building-office-2",
            keywords: ~w(locations datacenter)
          ),
          section(:racks, "Racks", ~p"/places/racks", "hero-server-stack",
            keywords: ~w(elevation)
          )
        ]
      },
      %{
        id: :network,
        label: "Network",
        question: "How is it connected?",
        icon: "hero-share",
        sections: [
          section(:topology, "Topology", ~p"/network/topology", "hero-share",
            keywords: ~w(links neighbors lldp)
          ),
          section(:vlans, "VLANs", ~p"/network/vlans", "hero-tag", keywords: ~w(layer2)),
          section(:vlan_groups, "VLAN groups", ~p"/network/vlan-groups", "hero-rectangle-group",
            keywords: ~w(layer2)
          ),
          section(:cables, "Cables", ~p"/network/cables", "hero-link", keywords: ~w(cabling))
        ]
      },
      %{
        id: :activity,
        label: "Activity",
        question: "What changed?",
        icon: "hero-clock",
        sections: [
          section(:activity, "Activity", ~p"/activity", "hero-clock",
            keywords: ~w(history audit changes)
          )
        ]
      },
      %{
        id: :catalog,
        label: "Catalog",
        question: "What can exist?",
        icon: "hero-book-open",
        sections: [
          section(:hardware_types, "Hardware types", ~p"/catalog/hardware-types", "hero-cpu-chip",
            keywords: ~w(models templates)
          ),
          section(:module_types, "Module types", ~p"/catalog/module-types", "hero-puzzle-piece",
            keywords: ~w(components templates)
          ),
          section(
            :manufacturers,
            "Manufacturers",
            ~p"/catalog/manufacturers",
            "hero-building-storefront",
            keywords: ~w(vendors)
          )
        ]
      }
    ]
  end

  @doc "Organization and personal configuration, outside the six areas."
  def settings do
    %{
      id: :settings,
      label: "Settings",
      question: "How is Renga set up?",
      icon: "hero-cog-6-tooth",
      sections: [
        section(:collectors, "Collectors", ~p"/settings/collectors", "hero-circle-stack",
          keywords: ~w(agents enrollment keys)
        ),
        section(:teams, "Teams", ~p"/settings/teams", "hero-user-group",
          keywords: ~w(owners ownership)
        ),
        section(:triage_rules, "Triage rules", ~p"/settings/triage-rules", "hero-funnel",
          keywords: ~w(rules triage automation subnet hostname labels)
        ),
        section(:organizations, "Organizations", ~p"/organizations", "hero-building-office",
          keywords: ~w(switch workspace)
        ),
        section(:account, "Account", ~p"/users/settings", "hero-user-circle",
          keywords: ~w(email password profile)
        )
      ]
    }
  end

  @doc """
  The sidebar link for a saved view: its name, the list it opens with its
  query, and whether it is shared with the organization.
  """
  def view_link(%Renga.SavedViews.SavedView{area: "inventory"} = view) do
    path = ~p"/inventory?#{Map.put(view.params, "view", view.id)}"
    %{id: view.id, label: view.name, path: path, shared?: is_nil(view.user_id)}
  end

  @doc "Every section id a page may pass as `active_nav`."
  def section_ids do
    for %{sections: sections} <- [settings() | areas()], %{id: id} <- sections, do: id
  end

  @doc """
  Finds the area and section for a page's `active_nav`. Returns `{nil, nil}`
  for pages outside the areas, such as sign-in, and raises for an unknown id
  so a mistyped section fails in tests instead of silently highlighting
  nothing.
  """
  def locate(nil), do: {nil, nil}

  def locate(section_id) do
    Enum.find_value([settings() | areas()], fn area ->
      case Enum.find(area.sections, &(&1.id == section_id)) do
        nil -> nil
        section -> {area, section}
      end
    end) || raise ArgumentError, "unknown navigation section #{inspect(section_id)}"
  end

  @doc "Where an area's sidebar entry goes: its first section."
  def path(%{sections: [first | _]}), do: first.path

  defp section(id, label, path, icon, opts) do
    %{id: id, label: label, path: path, icon: icon, keywords: Keyword.fetch!(opts, :keywords)}
  end
end
