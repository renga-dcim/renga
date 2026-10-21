defmodule RengaWeb.LimitsLive do
  @moduledoc """
  The organization's limits and current usage against them (RFD 21).

  The page is read-only: the deployment's operator sets limits with
  `renga-admin limits`, and owners can only see them. Only owners see the
  values.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Limits

  @impl true
  def mount(_params, _session, socket) do
    %{current_scope: scope} = socket.assigns
    owner? = "owner" in (scope.roles || [])

    {:ok,
     socket
     |> assign(:page_title, "Limits")
     |> assign(:owner?, owner?)
     |> assign(:limits, if(owner?, do: Limits.list(scope.organization), else: []))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:limits}
    >
      <.settings_page
        id="limits"
        title="Limits"
        description="Set by this deployment's operator to keep each organization's use fair. Contact them to change a limit."
        class="max-w-3xl"
      >
        <p :if={!@owner?} id="limits-owners-only" class="text-sm text-fg-muted">
          Only organization owners can see limits.
        </p>

        <div
          :if={@owner?}
          id="limits-list"
          class="divide-y divide-line rounded-lg border border-edge bg-surface"
        >
          <div
            :for={limit <- @limits}
            id={"limit-#{limit.name}"}
            class="flex flex-wrap items-center gap-3 px-3 py-2.5"
          >
            <div class="min-w-0 flex-1">
              <p class="text-sm font-medium text-fg">{limit_label(limit.name)}</p>
              <p class="text-xs text-fg-muted">{limit.description}</p>
            </div>
            <p class="text-sm tabular-nums text-fg">
              <span id={"limit-#{limit.name}-usage"}>{format_number(limit.usage)}</span>
              <span class="text-fg-muted">of</span>
              <span id={"limit-#{limit.name}-value"}>{format_number(limit.value)}</span>
              <span class="text-fg-muted">{limit.unit}</span>
            </p>
            <span
              :if={limit.overridden?}
              id={"limit-#{limit.name}-override"}
              class="text-xs text-fg-muted"
            >
              Set for this organization
            </span>
          </div>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp limit_label(name) do
    name |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_number(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
