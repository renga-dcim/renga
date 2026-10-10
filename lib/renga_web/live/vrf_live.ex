defmodule RengaWeb.VrfLive do
  @moduledoc """
  Network → VRFs (RFD 4, Phase 2): the organization's routing tables. The
  global table is always listed first; it has no record and cannot be edited
  or deleted. Each table links to its prefixes.

  Owners and admins create and edit VRFs in a side panel and delete empty
  ones. A VRF that still holds prefixes cannot be deleted, because its
  prefixes would otherwise have to fall into the global table. As RFD 8 sets
  for the Network area, the controls are hidden on a phone.

  An organization models a handful of routing namespaces, so the list is a
  plain assign, as for teams.

  Routing domains (Phase 6) lists what collectors report interfaces in, per
  source and key, and what each resolved to. Owners and admins map a key to
  a VRF or the global table, or leave it to automatic matching, and choose
  which sources' claims are authoritative enough to call a managed
  assignment wrong.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Inventory
  alias Renga.Inventory.Changes
  alias Renga.IPAM
  alias Renga.IPAM.RoutingDomains
  alias Renga.IPAM.Vrf

  @reload_after_ms 400

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Changes.subscribe(scope)

    {:ok,
     socket
     |> assign(
       page_title: "VRFs",
       can_manage?: Inventory.organization_manager?(scope),
       editing: nil,
       panel_open?: false,
       reload_timer: nil
     )
     |> assign_form(%Vrf{})
     |> load_tables()}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, socket |> assign(editing: nil, panel_open?: true) |> assign_form(%Vrf{})}
  end

  # Editing starts from the stored VRF, which is also the stale-edit baseline.
  def handle_event("edit", %{"id" => id}, socket) do
    vrf = IPAM.get_vrf!(socket.assigns.current_scope, id)
    {:noreply, socket |> assign(editing: vrf, panel_open?: true) |> assign_form(vrf)}
  rescue
    Ecto.NoResultsError -> {:noreply, vrf_gone(socket)}
    Ecto.Query.CastError -> {:noreply, vrf_gone(socket)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, socket |> assign(editing: nil, panel_open?: false) |> assign_form(%Vrf{})}
  end

  def handle_event("validate", %{"vrf" => attrs}, socket) do
    form =
      (socket.assigns.editing || %Vrf{})
      |> IPAM.change_vrf(attrs)
      |> Map.put(:action, :validate)
      |> to_form(id: socket.assigns.form.id)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"vrf" => attrs}, socket) do
    %{current_scope: scope, editing: editing} = socket.assigns

    result =
      if editing,
        do: IPAM.update_vrf(scope, editing, attrs),
        else: IPAM.create_vrf(scope, attrs)

    case result do
      {:ok, vrf} ->
        {:noreply,
         socket
         |> put_flash(:info, "VRF #{vrf.name} #{if editing, do: "saved", else: "created"}")
         |> close_overlay("vrf-panel")
         |> assign(editing: nil, panel_open?: false)
         |> assign_form(%Vrf{})
         |> load_tables()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, id: socket.assigns.form.id))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage VRFs")}

      {:error, :stale} ->
        {:noreply,
         assign(
           socket,
           :edit_error,
           "This VRF changed elsewhere. Close the panel and edit it again to see the current version."
         )}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, vrf_gone(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case IPAM.delete_vrf(scope, IPAM.get_vrf!(scope, id)) do
      {:ok, vrf} ->
        {:noreply, socket |> put_flash(:info, "VRF #{vrf.name} deleted") |> load_tables()}

      {:error, :in_use} ->
        {:noreply,
         socket
         |> put_flash(:error, "Move or delete the VRF's prefixes before deleting it")
         |> load_tables()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage VRFs")}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, vrf_gone(socket)}
    Ecto.Query.CastError -> {:noreply, vrf_gone(socket)}
  end

  # The mapping is looked up from the reloaded list, never taken from the
  # client; an unchanged choice writes nothing.
  def handle_event("map_domain", %{"mapping" => params}, socket) do
    %{current_scope: scope} = socket.assigns
    %{"source_id" => source_id, "key" => key, "target" => target} = params
    domain = Enum.find(RoutingDomains.list_reported(scope), &same_domain?(&1, source_id, key))

    result =
      case {domain, target} do
        {nil, _} -> {:error, :gone}
        {%{mapping: nil}, "automatic"} -> {:ok, nil}
        {%{mapping: mapping}, "automatic"} -> RoutingDomains.delete_mapping(scope, mapping.id)
        {_, "global"} -> RoutingDomains.put_mapping(scope, source_id, domain.key, nil)
        {_, vrf_id} -> RoutingDomains.put_mapping(scope, source_id, domain.key, vrf_id)
      end

    {:noreply, socket |> mapping_result(result, key) |> load_routing_domains()}
  rescue
    Ecto.NoResultsError ->
      {:noreply, socket |> mapping_result({:error, :gone}, "") |> load_tables()}

    Ecto.Query.CastError ->
      {:noreply, socket |> mapping_result({:error, :gone}, "") |> load_tables()}
  end

  def handle_event("set_authority", %{"authority" => params}, socket) do
    %{"source_id" => source_id, "authoritative" => value} = params

    case RoutingDomains.set_source_authority(
           socket.assigns.current_scope,
           source_id,
           value == "true"
         ) do
      {:ok, source} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{source.name}'s routing domains are #{if source.authoritative_routing_domains, do: "authoritative", else: "advisory"}"
         )
         |> load_routing_domains()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners and admins manage routing domains")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, socket |> put_flash(:error, "That source was deleted") |> load_tables()}

    Ecto.Query.CastError ->
      {:noreply, socket |> put_flash(:error, "That source was deleted") |> load_tables()}
  end

  @impl true
  def handle_info({:inventory_changed, _organization_id}, socket) do
    if socket.assigns.reload_timer, do: Process.cancel_timer(socket.assigns.reload_timer)

    {:noreply,
     assign(socket, :reload_timer, Process.send_after(self(), :reload, @reload_after_ms))}
  end

  # Only the list refreshes: an open edit keeps its draft and its baseline,
  # so a concurrent change is caught as stale on save.
  def handle_info(:reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_tables()}
  end

  defp vrf_gone(socket) do
    socket
    |> put_flash(:error, "That VRF was deleted")
    |> close_overlay("vrf-panel")
    |> assign(editing: nil, panel_open?: false)
    |> load_tables()
  end

  defp same_domain?(domain, source_id, key),
    do: domain.source.id == source_id and String.downcase(domain.key) == String.downcase(key)

  defp mapping_result(socket, {:ok, nil}, _key), do: socket
  defp mapping_result(socket, {:ok, _}, key), do: put_flash(socket, :info, "#{key} mapped")

  defp mapping_result(socket, {:error, :forbidden}, _key),
    do: put_flash(socket, :error, "Only owners and admins manage routing domains")

  defp mapping_result(socket, {:error, :gone}, _key),
    do: put_flash(socket, :error, "That routing domain or VRF is gone")

  defp mapping_result(socket, {:error, %Ecto.Changeset{}}, key),
    do: put_flash(socket, :error, "#{key} could not be mapped")

  # Explicit openings reset input identity; validation/reloads retain it.
  defp assign_form(socket, vrf) do
    assign(socket,
      edit_error: nil,
      form: to_form(IPAM.change_vrf(vrf), id: "vrf-fields-" <> Ecto.UUID.generate())
    )
  end

  defp load_tables(socket) do
    scope = socket.assigns.current_scope
    counts = IPAM.prefix_counts(scope)

    socket
    |> assign(
      global_count: Map.get(counts, nil, 0),
      vrfs: Enum.map(IPAM.list_vrfs(scope), &%{vrf: &1, prefix_count: Map.get(counts, &1.id, 0)})
    )
    |> load_routing_domains()
  end

  # Authority controls must remain available even without winning claims,
  # including after disabling a source so it can be enabled again.
  defp load_routing_domains(socket) do
    scope = socket.assigns.current_scope
    domains = RoutingDomains.list_reported(scope)
    sources = Inventory.list_sources(scope)

    assign(socket,
      routing_domains:
        Enum.map(domains, fn domain ->
          Map.put(
            domain,
            :form,
            to_form(
              %{
                "source_id" => domain.source.id,
                "key" => domain.key,
                "target" => mapping_target(domain.mapping)
              },
              as: :mapping,
              id: "routing-domain-#{domain_id(domain)}-form"
            )
          )
        end),
      authority_sources:
        Enum.map(sources, fn source ->
          %{
            source: source,
            form:
              to_form(
                %{
                  "source_id" => source.id,
                  "authoritative" => source.authoritative_routing_domains
                },
                as: :authority,
                id: "source-#{source.id}-authority-form"
              )
          }
        end)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:vrfs}
    >
      <section id="vrfs" class="mx-auto max-w-6xl space-y-6 px-6 py-6">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-xl font-semibold tracking-tight text-fg">VRFs</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Each VRF is a routing table of its own: the same CIDR can be planned once in each.
              Prefixes without a VRF are in the global table.
            </p>
          </div>
          <div :if={@can_manage?} class="hidden sm:block">
            <.button
              id="new-vrf"
              variant="primary"
              phx-click="new"
            >
              New VRF
            </.button>
          </div>
        </header>

        <.table
          id="vrf-list"
          rows={[:global | @vrfs]}
          row_id={&row_id/1}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={row} label="Routing table" class="py-2">
            <%= if row == :global do %>
              <span class="flex items-center gap-2">
                <span class="font-medium text-fg">Global</span>
                <span class="rounded border border-edge px-1.5 text-[11px] text-fg-muted">
                  default
                </span>
              </span>
              <span class="block text-xs text-fg-muted">Prefixes without a VRF</span>
            <% else %>
              <span class="flex items-center gap-2">
                <span class="font-medium wrap-anywhere text-fg">{row.vrf.name}</span>
                <%!-- The status column is hidden on a phone; only the
                      exception needs saying there. --%>
                <span
                  :if={row.vrf.status != "active"}
                  class="rounded border border-dashed border-warn-line px-1.5 text-[11px] text-warn-text sm:hidden"
                >
                  {String.capitalize(row.vrf.status)}
                </span>
              </span>
              <span :if={row.vrf.description} class="block text-xs wrap-anywhere text-fg-muted">
                {row.vrf.description}
              </span>
            <% end %>
          </:col>
          <:col :let={row} label="Route distinguisher" class="hidden whitespace-nowrap sm:table-cell">
            <span :if={row != :global && row.vrf.route_distinguisher} class="font-mono text-xs">
              {row.vrf.route_distinguisher}
            </span>
          </:col>
          <:col :let={row} label="Status" class="hidden whitespace-nowrap sm:table-cell">
            <span
              :if={row != :global}
              id={"vrf-#{row.vrf.id}-status"}
              class={[
                "inline-flex items-center rounded-md border px-2 py-0.5 text-xs",
                if(row.vrf.status == "active",
                  do: "border-edge text-fg",
                  else: "border-dashed border-warn-line text-warn-text"
                )
              ]}
            >
              {String.capitalize(row.vrf.status)}
            </span>
          </:col>
          <:col :let={row} label="Prefixes" class="whitespace-nowrap text-right">
            <.link
              id={"#{row_id(row)}-prefixes"}
              navigate={prefixes_path(row)}
              class="inline-flex min-h-tap min-w-tap items-center justify-end font-mono text-xs tabular-nums text-link hover:underline"
            >
              {prefix_label(prefix_count(row, @global_count))}
            </.link>
          </:col>
          <:action :let={row} :if={@can_manage?}>
            <div :if={row != :global} class="hidden justify-end gap-3 sm:flex">
              <button
                id={"vrf-#{row.vrf.id}-edit"}
                type="button"
                phx-click={JS.push("edit", value: %{id: row.vrf.id})}
                class="min-h-tap cursor-pointer text-sm text-link hover:underline"
              >
                Edit
              </button>
              <button
                id={"vrf-#{row.vrf.id}-delete"}
                type="button"
                disabled={row.prefix_count > 0}
                title={
                  row.prefix_count > 0 &&
                    "Move or delete its #{prefix_label(row.prefix_count)} first"
                }
                phx-click={show_overlay("delete-vrf-#{row.vrf.id}")}
                class="min-h-tap cursor-pointer text-sm text-crit hover:underline disabled:cursor-not-allowed disabled:text-fg-subtle disabled:no-underline"
              >
                Delete
              </button>
            </div>
          </:action>
        </.table>

        <p :if={@vrfs == []} id="vrfs-empty" class="text-sm text-fg-muted">
          No VRFs yet. Every prefix is in the global table until a VRF models another routing
          namespace.
        </p>

        <.routing_domains
          domains={@routing_domains}
          sources={@authority_sources}
          vrfs={@vrfs}
          can_manage?={@can_manage?}
        />
      </section>

      <.confirm_dialog
        :for={%{vrf: vrf, prefix_count: 0} <- @vrfs}
        :if={@can_manage?}
        id={"delete-vrf-#{vrf.id}"}
        title={"Delete #{vrf.name}?"}
        confirm_label="Delete VRF"
        on_confirm={JS.push("delete", value: %{id: vrf.id})}
      >
        It holds no prefixes. Activity keeps its history.
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage? && @panel_open?}
        id="vrf-panel"
        show
        on_cancel={JS.push("cancel")}
        title={if @editing, do: "Edit #{@editing.name}", else: "New VRF"}
        description="Names are unique regardless of case. Renaming a VRF relabels its prefixes."
      >
        <.form
          for={@form}
          id="vrf-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-1"
        >
          <p :if={@edit_error} id="vrf-edit-conflict" role="alert" class="mb-4 text-sm text-crit">
            {@edit_error}
          </p>
          <.input field={@form[:name]} type="text" label="Name" autocomplete="off" />
          <.input
            field={@form[:route_distinguisher]}
            type="text"
            label="Route distinguisher (optional)"
            placeholder="65000:100"
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:status]}
            type="select"
            label="Status"
            options={Enum.map(Vrf.statuses(), &{String.capitalize(&1), &1})}
          />
          <.input field={@form[:description]} type="text" label="Description (optional)" />
        </.form>
        <:footer>
          <.button id="save-vrf" variant="primary" form="vrf-form" phx-disable-with="Saving…">
            {if @editing, do: "Save VRF", else: "Create VRF"}
          </.button>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end

  attr :domains, :list, required: true
  attr :sources, :list, required: true
  attr :vrfs, :list, required: true
  attr :can_manage?, :boolean, required: true

  # Collectors name routing domains in their own words; this is where those
  # words meet the managed VRFs.
  defp routing_domains(assigns) do
    assigns =
      assign(
        assigns,
        :targets,
        [{"Automatic", "automatic"}, {"Global table", "global"}] ++
          Enum.map(assigns.vrfs, &{"VRF #{&1.vrf.name}", &1.vrf.id})
      )

    ~H"""
    <section id="routing-domains" class="space-y-3 pt-4">
      <div>
        <h2 class="text-base font-semibold text-fg">Routing domains</h2>
        <p class="mt-1 max-w-2xl text-sm text-fg-muted">
          What collectors report interfaces in. A key resolves to a VRF by mapping, route
          distinguisher, or name; <span class="font-mono">default</span>
          is the global table. Addresses on an unmapped domain are left out of every comparison
          until it is mapped.
        </p>
      </div>

      <p :if={@domains == []} id="routing-domains-empty" class="text-sm text-fg-muted">
        No collector reports routing domains. Interfaces without a claim are in the global table.
      </p>

      <.table
        :if={@domains != []}
        id="routing-domain-list"
        rows={@domains}
        row_id={&"routing-domain-#{domain_id(&1)}"}
        class="rounded-lg border border-edge bg-surface"
      >
        <:col :let={domain} label="Reported" class="py-2">
          <span class="block font-mono text-sm wrap-anywhere text-fg">{domain.key}</span>
          <span class="block text-xs text-fg-muted">{domain.source.name}</span>
          <%!-- The mapping column is hidden on a phone; only an explicit
                mapping needs saying there. --%>
          <span :if={domain.mapping} class="block text-xs text-fg-muted sm:hidden">
            Mapped to {mapping_label(domain.mapping)}
          </span>
        </:col>
        <:col :let={domain} label="Resolves to">
          <span
            :if={domain.outcomes == []}
            class="text-xs text-fg-muted"
          >
            Not reported now
          </span>
          <span class="flex flex-wrap gap-1.5">
            <span
              :for={outcome <- domain.outcomes}
              data-resolution={outcome.resolution}
              class={[
                "inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs",
                if(outcome.resolution == "unmapped",
                  do: "border-warn-line bg-warn-fill text-warn-text",
                  else: "border-edge text-fg"
                )
              ]}
            >
              {outcome_label(outcome)}
              <span class="tabular-nums text-fg-muted">
                · {interface_label(outcome.interface_count)}
              </span>
            </span>
          </span>
        </:col>
        <:col :let={domain} label="Mapping" class="hidden whitespace-nowrap sm:table-cell">
          <.form
            :if={@can_manage?}
            for={domain.form}
            id={domain.form.id}
            phx-change="map_domain"
            class="min-w-44 [&_.field]:mb-0"
          >
            <input
              type="hidden"
              name={domain.form[:source_id].name}
              value={domain.form[:source_id].value}
            />
            <input type="hidden" name={domain.form[:key].name} value={domain.form[:key].value} />
            <.input
              field={domain.form[:target]}
              type="select"
              aria-label={"Map #{domain.key}"}
              options={@targets}
            />
          </.form>
          <span :if={!@can_manage?} class="text-xs text-fg-muted">
            {mapping_label(domain.mapping)}
          </span>
        </:col>
      </.table>

      <div :if={@sources != []} id="routing-domain-authority" class="space-y-2">
        <h3 class="text-sm font-medium text-fg">Authoritative sources</h3>
        <p class="max-w-2xl text-xs text-fg-muted">
          An authoritative source's claim wins over others for the same interface and can mark a
          managed assignment as being in the wrong VRF. Collectors that read a device's own
          configuration are authoritative by default.
        </p>
        <ul class="divide-y divide-line rounded-lg border border-edge bg-surface">
          <li
            :for={%{source: source, form: form} <- @sources}
            id={"source-#{source.id}-authority"}
            class="flex flex-wrap items-center justify-between gap-3 px-4 py-2"
          >
            <span>
              <span class="block text-sm text-fg">{source.name}</span>
              <span class="block text-xs text-fg-muted">{source.kind}</span>
            </span>
            <.form
              :if={@can_manage?}
              for={form}
              id={form.id}
              phx-change="set_authority"
              class="hidden sm:block [&_.field]:mb-0"
            >
              <input type="hidden" name={form[:source_id].name} value={form[:source_id].value} />
              <.input field={form[:authoritative]} type="checkbox" label="Authoritative" />
            </.form>
            <span class={["text-xs text-fg-muted", @can_manage? && "sm:hidden"]}>
              {if source.authoritative_routing_domains, do: "Authoritative", else: "Advisory"}
            </span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp domain_id(domain), do: domain_id(domain.source.id, domain.key)

  @doc false
  # Keys can carry any character; a digest keeps DOM ids valid and stable.
  def domain_id(source_id, key) do
    :crypto.hash(:sha256, source_id <> ":" <> String.downcase(key))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp mapping_target(nil), do: "automatic"
  defp mapping_target(%{vrf_id: nil}), do: "global"
  defp mapping_target(%{vrf_id: vrf_id}), do: vrf_id

  defp mapping_label(nil), do: "Automatic"
  defp mapping_label(%{vrf: nil}), do: "Global table"
  defp mapping_label(%{vrf: vrf}), do: "VRF #{vrf.name}"

  defp outcome_label(%{resolution: "unmapped"}), do: "Unmapped"
  defp outcome_label(%{vrf: nil}), do: "Global table"
  defp outcome_label(%{vrf: vrf}), do: "VRF #{vrf.name}"

  defp interface_label(1), do: "1 interface"
  defp interface_label(count), do: "#{count} interfaces"

  defp row_id(:global), do: "vrf-global"
  defp row_id(%{vrf: vrf}), do: "vrf-#{vrf.id}"

  defp prefix_count(:global, global_count), do: global_count
  defp prefix_count(%{prefix_count: count}, _global_count), do: count

  defp prefixes_path(:global), do: ~p"/network/prefixes"
  defp prefixes_path(%{vrf: vrf}), do: ~p"/network/prefixes?#{[vrf: vrf.name]}"

  defp prefix_label(1), do: "1 prefix"
  defp prefix_label(count), do: "#{count} prefixes"
end
