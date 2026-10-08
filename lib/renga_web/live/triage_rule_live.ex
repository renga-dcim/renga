defmodule RengaWeb.TriageRuleLive do
  @moduledoc """
  Settings → Triage rules: the organization's rules, grouped by kind, each
  read as a sentence ("reports from 10.20.0.0/16 → DC1").

  Owners and admins create and edit rules in a side panel that previews,
  as they type, how many resources the rule would change and how many it
  would leave alone because they already have the fact. Saving applies the
  rule straight away. Everyone else reads the list.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.DCIM
  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.Teams
  alias Renga.TriageRules
  alias Renga.TriageRules.Rule

  @kinds [
    {"network_location", "Network location",
     "Reports from a subnet, or through an intake key, put a resource at a site."},
    {"top_of_rack", "Top of rack",
     "A resource whose LLDP neighbor is a switch in a rack goes in that rack, never at a unit."},
    {"ownership", "Ownership",
     "A hostname pattern, or a label the collector sends, sets the owning team."}
  ]

  @suggestion_fields ~w(kind name match_on subnet intake_api_key_id hostname_pattern
                         label_key label_value site_id location_id team_id)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: "Triage rules",
       kinds: @kinds,
       can_manage?: TriageRules.can_manage?(scope),
       editing: nil,
       sites: DCIM.list_sites(scope),
       teams: Teams.list_teams(scope),
       intake_keys: Enum.filter(Inventory.list_intake_api_keys(scope), &(&1.status == "active"))
     )
     |> load_rules()
     |> assign(:suggested?, false)
     |> start_form(%Rule{kind: "network_location"})}
  end

  # A suggestion from an Inbox triage pattern arrives as rule attributes in
  # the URL and opens the panel prefilled, with its preview. Nothing is saved
  # until the person completes it.
  @impl true
  def handle_params(%{"kind" => kind} = params, _uri, socket)
      when kind in ~w(network_location top_of_rack ownership) do
    if socket.assigns.can_manage? and not socket.assigns.suggested? do
      attrs = Map.take(params, @suggestion_fields)

      {:noreply,
       socket
       |> assign(editing: nil, suggested?: true)
       |> start_form(%Rule{kind: kind})
       |> update_form(attrs, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> start_form(%Rule{kind: "network_location"})}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case TriageRules.get_rule(socket.assigns.current_scope, id) do
      nil -> {:noreply, load_rules(socket)}
      rule -> {:noreply, socket |> assign(:editing, rule) |> start_form(rule)}
    end
  end

  def handle_event("validate", %{"rule" => attrs}, socket) do
    {:noreply, update_form(socket, attrs, :validate)}
  end

  def handle_event("save", %{"rule" => attrs}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns
    attrs = form_attrs(socket, attrs)

    result =
      if editing,
        do: TriageRules.update_rule(scope, editing, attrs),
        else: TriageRules.create_rule(scope, attrs)

    case result do
      {:ok, %{rule: rule, applied: applied}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{rule.name} saved. #{applied_label(rule, applied)}")
         |> close_overlay("rule-panel")
         |> assign(:editing, nil)
         |> load_rules()
         |> clear_suggestion()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset), preview: nil)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, error_message(reason)) |> load_rules()}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case TriageRules.get_rule(scope, id) do
      %Rule{enabled: false} = rule ->
        # Enabling applies to the accumulated inventory, so review its
        # current impact in the same panel used for saving a rule.
        {:noreply, socket |> assign(:editing, rule) |> start_form(%{rule | enabled: true})}

      %Rule{} = rule ->
        case TriageRules.set_enabled(scope, rule, false) do
          {:ok, %{rule: rule}} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{rule.name} is off. What it already set stays.")
             |> load_rules()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      nil ->
        {:noreply, load_rules(socket)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with %Rule{} = rule <- TriageRules.get_rule(scope, id),
         {:ok, _rule} <- TriageRules.delete_rule(scope, rule) do
      {:noreply, socket |> put_flash(:info, "#{rule.name} deleted") |> load_rules()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      nil -> {:noreply, load_rules(socket)}
    end
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket),
    do: {:noreply, load_rules(socket)}

  # Once a suggested rule is saved, the URL no longer describes the page.
  defp clear_suggestion(%{assigns: %{suggested?: true}} = socket) do
    socket
    |> assign(:suggested?, false)
    |> push_patch(to: ~p"/settings/triage-rules")
  end

  defp clear_suggestion(socket), do: socket

  defp load_rules(socket) do
    rules = TriageRules.list_rules(socket.assigns.current_scope)
    assign(socket, :rules, Enum.group_by(rules, & &1.kind))
  end

  defp start_form(socket, %Rule{} = rule) do
    attrs =
      rule
      |> Map.take(
        ~w(kind name enabled subnet intake_api_key_id hostname_pattern label_key label_value site_id location_id team_id)a
      )
      |> Map.put(:match_on, Rule.match_on(rule))

    preview =
      case TriageRules.preview(socket.assigns.current_scope, attrs) do
        {:ok, preview} -> preview
        {:error, _changeset} -> nil
      end

    socket
    |> assign(:base_rule, rule)
    |> assign(:form, to_form(TriageRules.change_rule(rule, attrs)))
    |> assign(:preview, preview)
    |> assign_locations(rule.site_id)
  end

  # Every change re-checks the rule and, once it is complete, previews it.
  # The site picks which locations the form offers.
  defp update_form(socket, attrs, action) do
    attrs = form_attrs(socket, attrs)

    changeset =
      socket.assigns.base_rule
      |> TriageRules.change_rule(attrs)
      |> Map.put(:action, action)

    preview =
      case TriageRules.preview(socket.assigns.current_scope, attrs) do
        {:ok, preview} -> preview
        {:error, _changeset} -> nil
      end

    socket
    |> assign(form: to_form(changeset), preview: preview)
    |> assign_locations(Ecto.Changeset.get_field(changeset, :site_id))
  end

  # A rule's kind never changes once saved, and switching kinds in a new
  # rule starts from that kind's first condition.
  defp form_attrs(%{assigns: %{editing: %Rule{kind: kind}}}, attrs),
    do: attrs |> Map.put("kind", kind) |> default_match_on()

  defp form_attrs(_socket, attrs), do: default_match_on(attrs)

  defp default_match_on(%{"kind" => kind, "match_on" => match_on} = attrs) do
    case {kind, match_on} do
      {"network_location", match_on} when match_on in ~w(subnet intake_key) -> attrs
      {"network_location", _other} -> Map.put(attrs, "match_on", "subnet")
      {"ownership", match_on} when match_on in ~w(hostname label) -> attrs
      {"ownership", _other} -> Map.put(attrs, "match_on", "hostname")
      _top_of_rack -> attrs
    end
  end

  defp default_match_on(attrs), do: attrs

  defp assign_locations(socket, nil), do: assign(socket, :locations, [])

  defp assign_locations(socket, site_id) do
    locations =
      case Ecto.UUID.cast(site_id) do
        {:ok, id} -> DCIM.list_locations(socket.assigns.current_scope, id)
        :error -> []
      end

    assign(socket, :locations, locations)
  end

  defp applied_label(%Rule{enabled: false}, _applied), do: "It is off, so it set nothing."
  defp applied_label(rule, 0), do: "Nothing it matches is missing #{fact_noun(rule)} right now."
  defp applied_label(rule, 1), do: "It #{fact_verb(rule)} 1 resource."
  defp applied_label(rule, count), do: "It #{fact_verb(rule)} #{count} resources."

  defp fact_noun(rule) do
    case TriageRules.fact(rule) do
      :owner -> "an owner"
      :placement -> "a placement"
    end
  end

  defp fact_verb(rule) do
    case TriageRules.fact(rule) do
      :owner -> "set the owner on"
      :placement -> "placed"
    end
  end

  defp error_message(:forbidden), do: "Managing triage rules requires the owner or admin role"
  defp error_message(:not_found), do: "That rule no longer exists"
  defp error_message(_reason), do: "The rule could not be saved"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:triage_rules}
    >
      <section id="triage-rules" class="mx-auto max-w-4xl space-y-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">Triage rules</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Rules answer what triage would ask, from signals collectors send. They only fill a
              missing fact, so they never change what a person set, and they apply again as new
              resources report.
            </p>
          </div>
          <.button
            :if={@can_manage?}
            id="new-rule"
            variant="primary"
            phx-click={JS.push("new") |> show_overlay("rule-panel")}
          >
            New rule
          </.button>
        </header>

        <section
          :for={{kind, label, explanation} <- @kinds}
          id={"rules-#{kind}"}
          class="space-y-2"
        >
          <div>
            <h2 class="text-sm font-semibold text-fg">{label}</h2>
            <p class="text-xs text-fg-muted">{explanation}</p>
          </div>
          <ul class="divide-y divide-edge rounded-lg border border-edge bg-surface">
            <li
              :for={rule <- Map.get(@rules, kind, [])}
              id={"rule-#{rule.id}"}
              data-enabled={to_string(rule.enabled)}
              class={[
                "flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-3 transition-opacity",
                !rule.enabled && "opacity-60"
              ]}
            >
              <div class="min-w-0 flex-1">
                <p class="flex items-center gap-2 font-medium text-fg">
                  {rule.name}
                  <span
                    :if={!rule.enabled}
                    class="rounded-full border border-edge px-2 text-xs font-normal text-fg-muted"
                  >
                    Off
                  </span>
                </p>
                <p class="mt-0.5 text-sm text-fg-muted" data-role="sentence">
                  <span class="font-mono text-xs text-fg">{condition(rule)}</span>
                  <.icon name="hero-arrow-right-mini" class="mx-1 size-4 align-text-bottom" />
                  <span class="text-fg">{effect(rule)}</span>
                </p>
              </div>
              <div :if={@can_manage?} class="flex items-center gap-3">
                <button
                  id={"rule-#{rule.id}-edit"}
                  type="button"
                  phx-click={JS.push("edit", value: %{id: rule.id}) |> show_overlay("rule-panel")}
                  class="min-h-tap cursor-pointer text-sm text-link hover:underline"
                >
                  Edit
                </button>
                <button
                  id={"rule-#{rule.id}-toggle"}
                  type="button"
                  phx-click={
                    if rule.enabled,
                      do: JS.push("toggle", value: %{id: rule.id}),
                      else: JS.push("toggle", value: %{id: rule.id}) |> show_overlay("rule-panel")
                  }
                  class="min-h-tap cursor-pointer text-sm text-link hover:underline"
                >
                  {if rule.enabled, do: "Turn off", else: "Turn on"}
                </button>
                <button
                  id={"rule-#{rule.id}-delete"}
                  type="button"
                  phx-click={show_overlay("delete-rule-#{rule.id}")}
                  class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
                >
                  Delete
                </button>
              </div>
            </li>
            <li
              :if={Map.get(@rules, kind, []) == []}
              id={"rules-#{kind}-empty"}
              class="px-4 py-3 text-sm text-fg-muted"
            >
              No {String.downcase(label)} rules yet.
            </li>
          </ul>
        </section>

        <p :if={!@can_manage?} id="triage-rules-read-only" class="text-sm text-fg-muted">
          Owners and admins manage triage rules.
        </p>
      </section>

      <%= for {_kind, rules} <- @rules, rule <- rules, @can_manage? do %>
        <.confirm_dialog
          id={"delete-rule-#{rule.id}"}
          title={"Delete #{rule.name}?"}
          confirm_label="Delete rule"
          on_confirm={JS.push("delete", value: %{id: rule.id})}
        >
          What the rule already set stays, still marked as set by a rule. It stops applying to
          new resources.
        </.confirm_dialog>
      <% end %>

      <.side_panel
        :if={@can_manage?}
        id="rule-panel"
        show={@suggested?}
        title={if @editing, do: "Edit #{@editing.name}", else: "New triage rule"}
      >
        <.form for={@form} id="rule-form" phx-change="validate" phx-submit="save" class="space-y-1">
          <input
            id="rule_enabled"
            type="hidden"
            name={@form[:enabled].name}
            value={to_string(@form[:enabled].value)}
          />
          <.input
            :if={is_nil(@editing)}
            field={@form[:kind]}
            type="select"
            label="Kind"
            options={Enum.map(@kinds, fn {kind, label, _explanation} -> {label, kind} end)}
          />
          <.input field={@form[:name]} type="text" label="Name" required autocomplete="off" />

          <.network_location_fields
            :if={@form[:kind].value == "network_location"}
            form={@form}
            sites={@sites}
            locations={@locations}
            intake_keys={@intake_keys}
          />

          <p
            :if={@form[:kind].value == "top_of_rack"}
            id="rule-top-of-rack-help"
            class="rounded-md bg-sunken px-3 py-2 text-sm text-fg-muted"
          >
            Resources whose current LLDP neighbors are switches placed in one rack go in that
            rack. Switches themselves, and resources whose neighbors sit in different racks,
            are left for a person.
          </p>

          <.ownership_fields
            :if={@form[:kind].value == "ownership"}
            form={@form}
            teams={@teams}
          />

          <.rule_preview preview={@preview} kind={@form[:kind].value} />

          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("rule-panel")}>Cancel</.button>
            <.button id="rule-save" variant="primary" phx-disable-with="Applying…">
              Save and apply
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :sites, :list, required: true
  attr :locations, :list, required: true
  attr :intake_keys, :list, required: true

  defp network_location_fields(assigns) do
    ~H"""
    <.input
      field={@form[:match_on]}
      type="select"
      label="When a resource reports"
      options={[{"From a subnet", "subnet"}, {"Through an intake key", "intake_key"}]}
    />
    <.input
      :if={@form[:match_on].value != "intake_key"}
      field={@form[:subnet]}
      type="text"
      label="Subnet"
      placeholder="10.20.0.0/16"
      autocomplete="off"
      value={format_subnet(@form[:subnet].value)}
    />
    <.input
      :if={@form[:match_on].value == "intake_key"}
      field={@form[:intake_api_key_id]}
      type="select"
      label="Intake key"
      prompt="Choose a key"
      options={Enum.map(@intake_keys, &{&1.name, &1.id})}
    />
    <.input
      field={@form[:site_id]}
      type="select"
      label="Put it at site"
      prompt="Choose a site"
      options={Enum.map(@sites, &{&1.resource.name, &1.id})}
    />
    <.input
      :if={@locations != []}
      field={@form[:location_id]}
      type="select"
      label="Location (optional)"
      prompt="Anywhere at the site"
      options={Enum.map(@locations, &{&1.resource.name, &1.id})}
    />
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :teams, :list, required: true

  defp ownership_fields(assigns) do
    ~H"""
    <.input
      field={@form[:match_on]}
      type="select"
      label="When a resource has"
      options={[{"A hostname matching a pattern", "hostname"}, {"A collector label", "label"}]}
    />
    <.input
      :if={@form[:match_on].value != "label"}
      field={@form[:hostname_pattern]}
      type="text"
      label="Hostname pattern"
      placeholder="web-*"
      autocomplete="off"
    />
    <div :if={@form[:match_on].value == "label"} class="grid grid-cols-2 gap-2">
      <.input
        field={@form[:label_key]}
        type="text"
        label="Label"
        placeholder="team"
        autocomplete="off"
      />
      <.input
        field={@form[:label_value]}
        type="text"
        label="Value"
        placeholder="platform"
        autocomplete="off"
      />
    </div>
    <.input
      field={@form[:team_id]}
      type="select"
      label="Owning team"
      prompt="Choose a team"
      options={Enum.map(@teams, &{&1.name, &1.id})}
    />
    """
  end

  attr :preview, :map, default: nil
  attr :kind, :string, default: nil

  defp rule_preview(assigns) do
    ~H"""
    <div
      id="rule-preview"
      aria-live="polite"
      class="mt-3 space-y-2 rounded-md border border-edge bg-sunken px-3 py-2 text-sm"
    >
      <%= if @preview do %>
        <p id="rule-preview-will-set" class="font-medium text-fg">
          {preview_headline(@kind, @preview.will_set)}
        </p>
        <ul :if={@preview.examples != []} class="flex flex-wrap gap-1">
          <li
            :for={example <- @preview.examples}
            class="rounded border border-edge bg-surface px-1.5 font-mono text-xs text-fg"
          >
            {example.name}
          </li>
          <li :if={@preview.will_set > length(@preview.examples)} class="text-xs text-fg-muted">
            and {@preview.will_set - length(@preview.examples)} more
          </li>
        </ul>
        <p
          :if={@preview.has_value + @preview.set_by_person > 0}
          id="rule-preview-left-alone"
          class="text-xs text-fg-muted"
        >
          Leaves alone {resource_count(@preview.has_value + @preview.set_by_person)} that already {if @kind ==
                                                                                                        "ownership",
                                                                                                      do:
                                                                                                        "have an owner",
                                                                                                      else:
                                                                                                        "have a placement"}: {@preview.set_by_person} set by a person, {@preview.has_value} by a collector or another rule.
        </p>
      <% else %>
        <p class="text-fg-muted">Complete the rule to see what it would change.</p>
      <% end %>
    </div>
    """
  end

  defp preview_headline("ownership", count), do: "Sets the owner on #{resource_count(count)}"
  defp preview_headline(_kind, count), do: "Places #{resource_count(count)}"

  defp resource_count(1), do: "1 resource"
  defp resource_count(count), do: "#{count} resources"

  defp condition(%Rule{kind: "network_location", intake_api_key: %{name: name}}),
    do: "reports through #{name}"

  defp condition(%Rule{kind: "network_location", subnet: subnet}),
    do: "reports from #{format_subnet(subnet)}"

  defp condition(%Rule{kind: "top_of_rack"}), do: "LLDP neighbor switch's rack"

  defp condition(%Rule{kind: "ownership", label_key: key, label_value: value})
       when is_binary(key),
       do: "label #{key}=#{value}"

  defp condition(%Rule{kind: "ownership", hostname_pattern: pattern}), do: "hostname #{pattern}"

  defp effect(%Rule{kind: "network_location", site: site, location: location}) do
    [site, location]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" / ", & &1.resource.name)
  end

  defp effect(%Rule{kind: "top_of_rack"}), do: "that rack, no unit"
  defp effect(%Rule{kind: "ownership", team: team}), do: "owned by #{team.name}"

  defp format_subnet(%Postgrex.INET{address: address, netmask: netmask}) do
    "#{:inet.ntoa(address)}#{if netmask, do: "/#{netmask}"}"
  end

  defp format_subnet(value), do: value
end
