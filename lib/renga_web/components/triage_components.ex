defmodule RengaWeb.TriageComponents do
  @moduledoc """
  Triage as the Inbox shows it (RFD 8): resources missing facts a person
  usually supplies, and a panel that supplies them one resource at a time.
  The panel is a phone-complete task, so every control keeps a 44px target.
  """
  use RengaWeb, :html

  alias RengaWeb.Format

  @fact_labels %{
    placement: "Placement",
    hardware_type: "Hardware type",
    owner: "Owner",
    identity: "Identity"
  }

  @doc "The label for a missing fact."
  def fact_label(fact), do: Map.fetch!(@fact_labels, fact)

  attr :patterns, :list, required: true
  attr :can_create_rules?, :boolean, default: false

  @doc """
  Resources in triage that share a signal, each with the rule that would
  fill their missing fact. Creating the rule opens it prefilled, with its
  preview, in Settings → Triage rules.
  """
  def triage_patterns(assigns) do
    ~H"""
    <section
      :if={@patterns != []}
      id="triage-patterns"
      aria-labelledby="triage-patterns-title"
      class="space-y-2"
    >
      <div>
        <h2 id="triage-patterns-title" class="text-sm font-semibold text-fg">Patterns</h2>
        <p class="text-xs text-fg-muted">
          Resources missing the same fact for the same reason. One rule can fill them all.
        </p>
      </div>
      <ul class="grid gap-2 sm:grid-cols-2">
        <li
          :for={pattern <- @patterns}
          id={"triage-pattern-row-#{pattern_dom_id(pattern.id)}"}
          data-fact={pattern.fact}
          class="flex flex-col gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 transition-colors hover:border-fg-subtle"
        >
          <div class="flex items-start justify-between gap-2">
            <p class="min-w-0 font-mono text-sm text-fg">{pattern.label}</p>
            <span class="shrink-0 font-mono text-xs tabular-nums text-fg-muted">
              {pattern.count}
            </span>
          </div>
          <p class="text-xs text-fg-muted">
            Missing {String.downcase(fact_label(pattern.fact))} ·
            <span class="font-mono">{Enum.join(pattern.examples, ", ")}</span>
            <span :if={pattern.count > length(pattern.examples)}>
              and {pattern.count - length(pattern.examples)} more
            </span>
          </p>
          <.link
            :if={@can_create_rules?}
            id={"triage-pattern-rule-#{pattern_dom_id(pattern.id)}"}
            navigate={~p"/settings/triage-rules?#{pattern.suggestion}"}
            class="inline-flex min-h-tap items-center gap-1 self-start text-sm text-link hover:underline sm:min-h-0"
          >
            <.icon name="hero-sparkles-mini" class="size-4" /> Create a rule
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  # Encode the complete identity: replacing punctuation makes distinct
  # collector labels share a LiveView patch key (for example ops.us/ops-us).
  defp pattern_dom_id(id), do: Base.url_encode64(id, padding: false)

  attr :id, :string, required: true
  attr :entries, :any, required: true
  attr :row_path, :any, required: true, doc: "a function from resource to its triage path"
  attr :selected_id, :string, default: nil
  attr :empty, :string, required: true

  @doc "Resources in triage in the shared list grammar."
  def triage_table(assigns) do
    ~H"""
    <.table
      id={@id}
      rows={@entries}
      row_item={fn {_id, item} -> item end}
      row_click={fn {_id, entry} -> JS.patch(@row_path.(entry.resource)) end}
      row_selected={fn {_id, entry} -> entry.resource.id == @selected_id end}
      class="rounded-lg border border-edge bg-surface"
    >
      <:col :let={entry} label="Resource" class="min-w-0 max-w-[24rem] py-2">
        <.link
          id={"#{@id}-link-#{entry.resource.id}"}
          patch={@row_path.(entry.resource)}
          class="block min-w-0 rounded-sm focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
        >
          <span class="block truncate font-medium text-fg">{resource_name(entry.resource)}</span>
          <span class="block truncate text-xs text-fg-muted">
            {Format.humanize(entry.resource.kind)}{host_hint(entry.resource)}
          </span>
        </.link>
      </:col>
      <:col :let={entry} label="Missing">
        <span class="flex flex-wrap gap-1">
          <span
            :for={fact <- entry.missing}
            data-missing={fact}
            class="rounded-sm border border-edge px-1.5 py-0.5 text-[11px] text-fg-muted"
          >
            {fact_label(fact)}
          </span>
        </span>
      </:col>
      <:col
        :let={entry}
        label="Added"
        class="hidden whitespace-nowrap text-right font-mono text-xs text-fg-muted sm:table-cell"
      >
        <time
          datetime={DateTime.to_iso8601(entry.resource.inserted_at)}
          title={Format.datetime(entry.resource.inserted_at)}
        >
          {Format.age(entry.resource.inserted_at)}
        </time>
      </:col>
      <:empty>{@empty}</:empty>
    </.table>
    """
  end

  attr :resource, :map, required: true
  attr :missing, :list, required: true
  attr :candidates, :list, required: true
  attr :teams, :list, required: true
  attr :places, :map, required: true, doc: "sites, locations, and racks to place into"
  attr :can_manage?, :boolean, required: true
  attr :on_cancel, JS, required: true

  @doc "Supplies a resource's missing facts, one at a time."
  def triage_panel(assigns) do
    ~H"""
    <.side_panel
      id="triage-panel"
      title={resource_name(@resource)}
      description="Facts a person usually supplies"
      show
      on_cancel={@on_cancel}
    >
      <div class="space-y-5">
        <p
          :if={@missing == []}
          id="triage-done"
          class="rounded-md border border-edge bg-sunken px-3 py-2 text-sm text-fg"
        >
          <.icon name="hero-check-mini" class="size-4 align-[-3px] text-ok" />
          Nothing is missing; this resource has left triage.
        </p>

        <section :if={:owner in @missing} id="triage-owner" class="space-y-1.5">
          <h3 class="text-xs font-medium text-fg-muted">Owner</h3>
          <form
            :if={@can_manage? and @teams != []}
            id="triage-owner-form"
            phx-submit="triage_owner"
            class="flex gap-2"
          >
            <label for="triage-owner-team" class="sr-only">Owning team</label>
            <select
              id="triage-owner-team"
              name="team"
              class="h-control min-h-tap min-w-0 flex-1 rounded-md border border-edge bg-surface px-2 text-sm text-fg"
            >
              <option :for={team <- @teams} value={team.id}>{team.name}</option>
            </select>
            <.button id="triage-owner-save" variant="primary">Set owner</.button>
          </form>
          <p :if={@can_manage? and @teams == []} class="text-sm text-fg-muted">
            <.link navigate={~p"/settings/teams"} class="text-link hover:underline">
              Create a team
            </.link>
            to assign owners.
          </p>
          <p :if={!@can_manage?} id="triage-owner-request" class="text-sm text-fg-muted">
            <.link navigate={~p"/inventory/#{@resource}"} class="text-link hover:underline">
              Request an owner
            </.link>
            from the resource page; owners and admins set it.
          </p>
        </section>

        <section :if={:placement in @missing} id="triage-placement" class="space-y-1.5">
          <h3 class="text-xs font-medium text-fg-muted">Placement</h3>
          <form
            :if={@can_manage? and @places.sites != []}
            id="triage-placement-form"
            phx-submit="triage_place"
            class="space-y-2"
          >
            <p class="text-xs text-fg-muted">
              Choose a rack, or only a site and location. Triage never picks a rack unit; set it
              from the rack when the device is mounted.
            </p>
            <.input
              id="triage-placement-rack"
              name="placement[rack_id]"
              type="select"
              label="Rack"
              value=""
              prompt="No rack"
              options={Enum.map(@places.racks, &{rack_label(&1), &1.id})}
            />
            <.input
              id="triage-placement-site"
              name="placement[site_id]"
              type="select"
              label="Or a site"
              value=""
              prompt="Choose a site"
              options={Enum.map(@places.sites, &{&1.resource.name, &1.id})}
            />
            <.input
              id="triage-placement-location"
              name="placement[location_id]"
              type="select"
              label="Location (optional)"
              value=""
              prompt="No location"
              options={Enum.map(@places.locations, &{location_label(&1), &1.id})}
            />
            <div class="flex justify-end">
              <.button id="triage-placement-save" variant="primary">Place</.button>
            </div>
          </form>
          <p :if={@can_manage? and @places.sites == []} class="text-sm text-fg-muted">
            <.link navigate={~p"/places"} class="text-link hover:underline">Add a site</.link>
            to place resources.
          </p>
          <p :if={!@can_manage?} id="triage-placement-unavailable" class="text-sm text-fg-muted">
            Placing resources requires the owner or admin role.
          </p>
        </section>

        <section :if={:hardware_type in @missing} id="triage-hardware" class="space-y-1.5">
          <h3 class="text-xs font-medium text-fg-muted">Hardware type</h3>
          <p class="text-sm text-fg-muted">
            Reported vendor and model did not match one catalog type.
            <.link navigate={~p"/inventory/#{@resource}/hardware"} class="text-link hover:underline">
              Choose it on the Hardware tab
            </.link>
          </p>
        </section>

        <section :if={:identity in @missing} id="triage-identity" class="space-y-1.5">
          <h3 class="text-xs font-medium text-fg-muted">Identity</h3>
          <p class="text-sm text-fg-muted">
            A report matched this resource and others equally well, so Renga could not tell
            which it describes. It leaves triage when a later report matches one resource.
          </p>
          <ul class="divide-y divide-line rounded-md border border-edge text-sm">
            <li :for={candidate <- @candidates} id={"triage-candidate-#{candidate.id}"}>
              <.link
                navigate={~p"/inventory/#{candidate}/sources"}
                class="flex min-h-tap items-center px-3 text-link hover:underline"
              >
                {resource_name(candidate)}
              </.link>
            </li>
          </ul>
          <.link
            navigate={~p"/inventory/#{@resource}/sources"}
            class="inline-flex min-h-tap items-center text-sm text-link hover:underline"
          >
            Compare identifiers on the Sources tab
          </.link>
        </section>
      </div>
    </.side_panel>
    """
  end

  defp resource_name(resource), do: resource.display_name || resource.name

  defp host_hint(%{host: %{hostname: hostname}}) when is_binary(hostname), do: " · #{hostname}"
  defp host_hint(_resource), do: ""

  defp rack_label(rack) do
    [
      rack.site && rack.site.resource.name,
      rack.location && rack.location.resource.name,
      rack.resource.name
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp location_label(location), do: "#{location.site.resource.name} / #{location.resource.name}"
end
