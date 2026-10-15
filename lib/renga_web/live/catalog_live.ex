defmodule RengaWeb.CatalogLive do
  use RengaWeb, :live_view

  import RengaWeb.CatalogComponents, only: [used_by: 1]

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Catalog
  alias Renga.Catalog.ComponentTemplate
  alias Renga.Catalog.Drafts
  alias Renga.Catalog.Moves
  alias Renga.Catalog.TypeRevision

  @device_class_options Enum.map(
                          ~w(server switch appliance chassis pdu storage other),
                          &{Phoenix.Naming.humanize(&1), &1}
                        )
  @module_class_options Enum.map(
                          ~w(line_card supervisor power_supply fan_tray transceiver other),
                          &{Phoenix.Naming.humanize(&1), &1}
                        )
  @airflow_options Enum.map(
                     ~w(front_to_rear rear_to_front left_to_right right_to_left passive mixed),
                     &{Phoenix.Naming.humanize(&1), &1}
                   )
  @component_kind_options Enum.map(
                            ~w(interface module_bay power_port power_outlet console_port device_bay cpu memory disk),
                            &{Phoenix.Naming.humanize(&1), &1}
                          )
  @revision_scalar_fields ~w(part_number height_units width_mm depth_mm weight_kg airflow specifications)
  @template_scalar_fields ~w(kind name label position description required attributes)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       manufacturers_empty?: true,
       hardware_types_empty?: true,
       module_types_empty?: true,
       can_author_catalog?: Catalog.catalog_author?(socket.assigns.current_scope),
       device_class_options: @device_class_options,
       module_class_options: @module_class_options,
       manufacturer_options: [],
       manufacturer_form: catalog_form(:manufacturer),
       hardware_type_form: catalog_form(:hardware_type),
       module_type_form: catalog_form(:module_type),
       revision_params: default_revision_params(),
       revision_form: revision_form(default_revision_params()),
       template_errors: %{},
       airflow_options: @airflow_options,
       component_kind_options: @component_kind_options
     )
     |> stream(:manufacturers, [], dom_id: &"manufacturer-#{&1.id}")
     |> stream(:hardware_types, [], dom_id: &"hardware-type-#{&1.id}")
     |> stream(:module_types, [], dom_id: &"module-type-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope

    socket =
      case socket.assigns.live_action do
        :manufacturers ->
          manufacturers = Catalog.list_manufacturers(scope)

          socket
          |> assign(page_title: "Manufacturers", manufacturers_empty?: manufacturers == [])
          |> stream(:manufacturers, manufacturers, reset: true)

        :hardware_types ->
          hardware_types = Catalog.list_hardware_types(scope)

          socket
          |> assign(page_title: "Hardware types", hardware_types_empty?: hardware_types == [])
          |> assign_manufacturer_options(scope)
          |> stream(:hardware_types, hardware_types, reset: true)

        :hardware_type ->
          hardware_type = Catalog.get_hardware_type!(scope, params["id"])

          socket
          |> assign(
            page_title: hardware_type.model,
            hardware_type: hardware_type,
            draft: Drafts.get_draft(scope, hardware_type),
            used_by_selected: MapSet.new(),
            can_set_auto_move?: Catalog.can_change_expectations?(scope)
          )
          |> assign_used_by()
          |> reset_revision_form()

        :module_types ->
          module_types = Catalog.list_module_types(scope)

          socket
          |> assign(page_title: "Module types", module_types_empty?: module_types == [])
          |> assign_manufacturer_options(scope)
          |> stream(:module_types, module_types, reset: true)

        :module_type ->
          module_type = Catalog.get_module_type!(scope, params["id"])

          socket
          |> assign(page_title: module_type.model, module_type: module_type)
          |> reset_revision_form()
      end

    {:noreply, socket}
  end

  @impl true
  # Hardware types are edited as drafts (RFD 8, "Editing hardware
  # components"); the one-shot revision form remains for module types.
  def handle_event("start_draft", _params, socket) do
    %{current_scope: scope, hardware_type: hardware_type} = socket.assigns

    case Drafts.start_draft(scope, hardware_type) do
      {:ok, _draft} ->
        {:noreply, push_navigate(socket, to: ~p"/catalog/hardware-types/#{hardware_type}/draft")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to author the catalog")}
    end
  end

  # Resources move between revisions only when someone moves them, one by
  # one from their Hardware tab or together here (RFD 8).
  def handle_event("toggle_used_by", %{"id" => id}, socket) do
    selected = socket.assigns.used_by_selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :used_by_selected, selected)}
  end

  def handle_event("select_fitting", _params, socket) do
    %{used_by: entries, latest_revision: latest} = socket.assigns

    fitting =
      for entry <- entries,
          latest && entry.revision < latest.revision,
          Moves.fits_entry?(entry),
          into: MapSet.new(),
          do: entry.resource.id

    {:noreply, assign(socket, :used_by_selected, fitting)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :used_by_selected, MapSet.new())}
  end

  def handle_event("move_selected", _params, socket) do
    %{current_scope: scope, latest_revision: latest, used_by: entries} = socket.assigns

    ids =
      for entry <- entries,
          latest && entry.revision < latest.revision,
          MapSet.member?(socket.assigns.used_by_selected, entry.resource.id),
          do: entry.resource.id

    case ids != [] && Moves.move(scope, ids, latest.id) do
      {:ok, %{moved: moved}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Moved #{moved} to revision #{latest.revision}")
         |> assign(:used_by_selected, MapSet.new())
         |> assign_used_by()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to move resources")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Those resources could not be moved; review them and try again")
         |> assign_used_by()}

      false ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_auto_move", _params, socket) do
    %{current_scope: scope, hardware_type: hardware_type} = socket.assigns

    case Catalog.set_auto_move(scope, hardware_type, not hardware_type.auto_move) do
      {:ok, updated} ->
        {:noreply,
         assign(socket, :hardware_type, %{hardware_type | auto_move: updated.auto_move})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Automatic moves need the owner or admin role")}
    end
  end

  def handle_event("create_manufacturer", %{"manufacturer" => params}, socket) do
    scope = socket.assigns.current_scope

    case Catalog.create_manufacturer(
           scope,
           %{
             name: params["name"],
             display_name: params["name"],
             lifecycle_state: "active"
           },
           %{slug: params["slug"], description: blank_to_nil(params["description"])}
         ) do
      {:ok, _manufacturer} ->
        {:noreply,
         socket
         |> put_flash(:info, "Manufacturer created")
         |> push_navigate(to: ~p"/catalog/manufacturers")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:manufacturer_form, catalog_form(:manufacturer, params))
         |> put_flash(:error, first_error(changeset))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to author the catalog")}
    end
  end

  def handle_event("create_hardware_type", %{"hardware_type" => params}, socket) do
    create_catalog_type(socket, :hardware_type, params)
  end

  def handle_event("create_module_type", %{"module_type" => params}, socket) do
    create_catalog_type(socket, :module_type, params)
  end

  def handle_event("validate_revision", %{"revision" => params}, socket) when is_map(params) do
    if safe_revision_param_shapes?(params) do
      params = normalize_revision_params(params, socket.assigns.revision_params)

      case revision_submission(params) do
        {:ok, _revision_attrs, _templates} ->
          {:noreply, assign_revision_form(socket, params, [], %{}, :validate)}

        {:error, revision_errors, template_errors} ->
          {:noreply,
           assign_revision_form(socket, params, revision_errors, template_errors, :validate)}
      end
    else
      {:noreply, invalid_revision_submission(socket, :validate)}
    end
  end

  def handle_event("validate_revision", _params, socket) do
    {:noreply, invalid_revision_submission(socket, :validate)}
  end

  def handle_event("add_component_template", _params, socket) do
    params =
      Map.update!(socket.assigns.revision_params, "templates", fn templates ->
        templates
        |> template_params_list()
        |> Kernel.++([default_template_params()])
        |> index_template_params()
      end)

    {:noreply, assign_revision_form(socket, params)}
  end

  def handle_event("remove_component_template", %{"id" => id}, socket) do
    templates =
      socket.assigns.revision_params["templates"]
      |> template_params_list()
      |> Enum.reject(&(&1["_persistent_id"] == id))
      |> case do
        [] -> [default_template_params()]
        templates -> templates
      end
      |> index_template_params()

    params = Map.put(socket.assigns.revision_params, "templates", templates)
    {:noreply, assign_revision_form(socket, params)}
  end

  def handle_event("remove_component_template", _params, socket) do
    {:noreply, put_flash(socket, :error, "Component template could not be removed")}
  end

  def handle_event("publish_revision", %{"revision" => params}, socket) when is_map(params) do
    if safe_revision_param_shapes?(params) do
      publish_revision(socket, normalize_revision_params(params, socket.assigns.revision_params))
    else
      {:noreply,
       socket
       |> invalid_revision_submission(:insert)
       |> put_flash(:error, "Revision submission is invalid")}
    end
  end

  def handle_event("publish_revision", _params, socket) do
    {:noreply,
     socket
     |> invalid_revision_submission(:insert)
     |> put_flash(:error, "Revision submission is invalid")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={catalog_nav(@live_action)}
    >
      <section id="catalog-browser" class="mx-auto max-w-6xl space-y-6 px-6 py-6 lg:px-8">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle">
              DCIM catalog
            </p>
            <h1 class="mt-1 text-xl font-semibold tracking-tight text-fg">{@page_title}</h1>
            <p class="mt-1 max-w-2xl text-sm text-fg-muted">
              Organization-scoped, revision-pinned definitions for physical infrastructure.
            </p>
          </div>
          <.button
            :if={@can_author_catalog? and @live_action == :manufacturers}
            id="new-manufacturer"
            variant="primary"
            phx-click={show_overlay("new-manufacturer-panel")}
          >
            New manufacturer
          </.button>
          <.button
            :if={@can_author_catalog? and @live_action == :hardware_types}
            id="new-hardware-type"
            variant="primary"
            phx-click={show_overlay("new-hardware-type-panel")}
          >
            New hardware type
          </.button>
          <.button
            :if={@can_author_catalog? and @live_action == :module_types}
            id="new-module-type"
            variant="primary"
            phx-click={show_overlay("new-module-type-panel")}
          >
            New module type
          </.button>
        </header>

        <%= case @live_action do %>
          <% :manufacturers -> %>
            <.manufacturer_form :if={@can_author_catalog?} form={@manufacturer_form} />
            <.manufacturer_catalog
              manufacturers={@streams.manufacturers}
              empty?={@manufacturers_empty?}
            />
          <% :hardware_types -> %>
            <.catalog_type_form
              :if={@can_author_catalog?}
              id="new-hardware-type-form"
              panel_id="new-hardware-type-panel"
              form={@hardware_type_form}
              event="create_hardware_type"
              title="New hardware type"
              class_label="Device class"
              class_field={:device_class}
              class_options={@device_class_options}
              manufacturer_options={@manufacturer_options}
            />
            <.hardware_type_catalog
              hardware_types={@streams.hardware_types}
              empty?={@hardware_types_empty?}
            />
          <% :hardware_type -> %>
            <.catalog_type_detail
              catalog_type={@hardware_type}
              prefix="hardware-type"
              class_label="Device class"
              class_id="hardware-type-device-class"
              class_value={@hardware_type.device_class}
              can_author_catalog={@can_author_catalog?}
              authoring={:draft}
              draft={@draft}
              revision_form={@revision_form}
              template_errors={@template_errors}
              airflow_options={@airflow_options}
              component_kind_options={@component_kind_options}
            >
              <.used_by
                entries={@used_by}
                latest={@latest_revision}
                selected={@used_by_selected}
                auto_move={@hardware_type.auto_move}
                can_move?={@can_author_catalog?}
                can_set_auto_move?={@can_set_auto_move?}
              />
            </.catalog_type_detail>
          <% :module_types -> %>
            <.catalog_type_form
              :if={@can_author_catalog?}
              id="new-module-type-form"
              panel_id="new-module-type-panel"
              form={@module_type_form}
              event="create_module_type"
              title="New module type"
              class_label="Module class"
              class_field={:module_class}
              class_options={@module_class_options}
              manufacturer_options={@manufacturer_options}
            />
            <.module_type_catalog
              module_types={@streams.module_types}
              empty?={@module_types_empty?}
            />
          <% :module_type -> %>
            <.catalog_type_detail
              catalog_type={@module_type}
              prefix="module-type"
              class_label="Module class"
              class_id="module-type-module-class"
              class_value={@module_type.module_class}
              can_author_catalog={@can_author_catalog?}
              revision_form={@revision_form}
              template_errors={@template_errors}
              airflow_options={@airflow_options}
              component_kind_options={@component_kind_options}
            />
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true

  # Creating happens in a side panel (docs/design-system.md, "Interaction");
  # a successful create navigates away, so the panel never needs closing here.
  defp manufacturer_form(assigns) do
    ~H"""
    <.side_panel
      id="new-manufacturer-panel"
      title="New manufacturer"
      description="The normalized identity used by hardware and module definitions."
    >
      <.form for={@form} id="new-manufacturer-form" phx-submit="create_manufacturer" class="space-y-1">
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:slug]} type="text" label="Slug" required />
        <.input field={@form[:description]} type="text" label="Description" />
      </.form>
      <:footer>
        <.button
          id="create-manufacturer"
          type="submit"
          variant="primary"
          form="new-manufacturer-form"
          phx-disable-with="Creating…"
        >
          Create manufacturer
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  attr :id, :string, required: true
  attr :panel_id, :string, required: true
  attr :form, :map, required: true
  attr :event, :string, required: true
  attr :title, :string, required: true
  attr :class_label, :string, required: true
  attr :class_field, :atom, required: true
  attr :class_options, :list, required: true
  attr :manufacturer_options, :list, required: true

  defp catalog_type_form(assigns) do
    ~H"""
    <.side_panel
      id={@panel_id}
      title={@title}
      description="Define the catalog identity first; immutable revisions are published from its detail page."
    >
      <.form for={@form} id={@id} phx-submit={@event} class="space-y-1">
        <.input
          field={@form[:manufacturer_id]}
          type="select"
          label="Manufacturer"
          prompt="Select manufacturer"
          options={@manufacturer_options}
          required
        />
        <.input field={@form[:model]} type="text" label="Model" required />
        <.input
          field={@form[@class_field]}
          type="select"
          label={@class_label}
          prompt={"Select #{String.downcase(@class_label)}"}
          options={@class_options}
          required
        />
        <.input field={@form[:description]} type="text" label="Description" />
      </.form>
      <:footer>
        <.button
          id={"#{@id}-submit"}
          type="submit"
          variant="primary"
          form={@id}
          phx-disable-with="Creating…"
        >
          Create type
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  attr :manufacturers, :any, required: true
  attr :empty?, :boolean, required: true

  defp manufacturer_catalog(assigns) do
    ~H"""
    <.table
      id="manufacturers-list"
      rows={@manufacturers}
      overflow="clip"
      class="rounded-lg border border-edge bg-surface"
    >
      <:col :let={{_id, manufacturer}} label="Name" class="w-1/3">
        <span class="font-medium text-fg">{manufacturer.resource.name}</span>
      </:col>
      <:col :let={{_id, manufacturer}} label="Slug" class="w-1/4" hide_below="xl">
        <span class="font-mono text-xs text-fg-muted">{manufacturer.slug}</span>
      </:col>
      <:col :let={{_id, manufacturer}} label="Description" hide_below="3xl">
        <span :if={manufacturer.description} class="text-fg-muted">
          {manufacturer.description}
        </span>
        <span :if={!manufacturer.description} class="text-fg-subtle">No description</span>
      </:col>
      <:empty>
        <.catalog_empty
          :if={@empty?}
          id="manufacturers-empty"
          icon="hero-building-storefront"
          title="No manufacturers yet"
          detail="Catalog manufacturers will appear here."
        />
      </:empty>
    </.table>
    """
  end

  attr :hardware_types, :any, required: true
  attr :empty?, :boolean, required: true

  defp hardware_type_catalog(assigns) do
    ~H"""
    <.table
      id="hardware-types-list"
      rows={@hardware_types}
      row_navigate={fn {_id, type} -> ~p"/catalog/hardware-types/#{type.id}" end}
      overflow="clip"
      class="rounded-lg border border-edge bg-surface"
    >
      <:col :let={{_id, type}} label="Type" class="w-2/5">
        <span class="font-medium text-fg">{type.manufacturer.resource.name} {type.model}</span>
      </:col>
      <:col :let={{_id, type}} label="Device class" class="w-36">
        <span class="text-fg-muted">{humanize(type.device_class)}</span>
      </:col>
      <:col :let={{_id, type}} label="Description" hide_below="3xl">
        <span class="text-fg-muted">{type.description || type.resource.name}</span>
      </:col>
      <:empty>
        <.catalog_empty
          :if={@empty?}
          id="hardware-types-empty"
          icon="hero-server-stack"
          title="No hardware types yet"
          detail="Versioned hardware definitions will appear here."
        />
      </:empty>
    </.table>
    """
  end

  attr :module_types, :any, required: true
  attr :empty?, :boolean, required: true

  defp module_type_catalog(assigns) do
    ~H"""
    <.table
      id="module-types-list"
      rows={@module_types}
      row_navigate={fn {_id, type} -> ~p"/catalog/module-types/#{type.id}" end}
      overflow="clip"
      class="rounded-lg border border-edge bg-surface"
    >
      <:col :let={{_id, type}} label="Type" class="w-2/5">
        <span class="font-medium text-fg">{type.manufacturer.resource.name} {type.model}</span>
      </:col>
      <:col :let={{_id, type}} label="Module class" class="w-36">
        <span class="text-fg-muted">{humanize(type.module_class)}</span>
      </:col>
      <:col :let={{_id, type}} label="Description" hide_below="3xl">
        <span class="text-fg-muted">{type.description || type.resource.name}</span>
      </:col>
      <:empty>
        <.catalog_empty
          :if={@empty?}
          id="module-types-empty"
          icon="hero-puzzle-piece"
          title="No module types yet"
          detail="Versioned installable module definitions will appear here."
        />
      </:empty>
    </.table>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :detail, :string, required: true

  defp catalog_empty(assigns) do
    ~H"""
    <div id={@id} class="space-y-1">
      <.icon name={@icon} class="mx-auto size-6 text-fg-subtle" />
      <p class="text-sm font-medium text-fg">{@title}</p>
      <p class="text-xs text-fg-muted">{@detail}</p>
    </div>
    """
  end

  attr :catalog_type, :map, required: true
  attr :prefix, :string, required: true
  attr :class_label, :string, required: true
  attr :class_id, :string, required: true
  attr :class_value, :string, required: true
  attr :can_author_catalog, :boolean, required: true
  attr :authoring, :atom, default: :form, values: [:form, :draft]
  attr :draft, :any, default: nil
  slot :inner_block, doc: "type-specific sections shown before the revisions"
  attr :revision_form, :map, required: true
  attr :template_errors, :map, required: true
  attr :airflow_options, :list, required: true
  attr :component_kind_options, :list, required: true

  defp catalog_type_detail(assigns) do
    ~H"""
    <article id={"#{@prefix}-detail-#{@catalog_type.id}"} class="space-y-6">
      <section
        id={"#{@prefix}-identity"}
        class="grid gap-4 rounded-lg border border-edge bg-surface px-5 py-4 sm:grid-cols-[1fr_auto]"
      >
        <div class="min-w-0">
          <p class="text-xs font-medium text-fg-muted">
            {@catalog_type.manufacturer.resource.name}
          </p>
          <h2 class="mt-0.5 text-base font-semibold text-fg">{@catalog_type.model}</h2>
          <p class="mt-1 max-w-3xl text-sm text-fg-muted">
            {@catalog_type.description || "No type description provided."}
          </p>
        </div>
        <div class="sm:text-right">
          <p class="text-xs text-fg-muted">{@class_label}</p>
          <p id={@class_id} class="mt-0.5 text-sm font-medium text-fg">
            {humanize(@class_value)}
          </p>
        </div>
      </section>

      <section
        :if={@can_author_catalog and @authoring == :draft}
        id="draft-entry"
        class="flex flex-wrap items-center gap-4 rounded-lg border border-edge bg-surface p-4"
      >
        <div class="min-w-0 flex-1">
          <p class="text-sm font-medium text-fg">
            {if @draft,
              do: "Draft revision #{@draft.revision} in progress",
              else: "Edit this hardware type"}
          </p>
          <p class="text-xs text-fg-muted">
            Changes save to a draft as you make them. Publishing adds a revision; resources stay
            on theirs until they are moved.
          </p>
        </div>
        <.button
          :if={@draft}
          id="draft-continue"
          variant="primary"
          navigate={~p"/catalog/hardware-types/#{@catalog_type}/draft"}
        >
          Continue editing
        </.button>
        <.button :if={!@draft} id="draft-start" variant="primary" phx-click="start_draft">
          Edit
        </.button>
      </section>

      <.revision_authoring_form
        :if={@can_author_catalog and @authoring == :form}
        form={@revision_form}
        template_errors={@template_errors}
        airflow_options={@airflow_options}
        component_kind_options={@component_kind_options}
      />

      {render_slot(@inner_block)}

      <section
        id={"#{@prefix}-revisions"}
        aria-labelledby={"#{@prefix}-revisions-title"}
        class="space-y-3"
      >
        <div>
          <h2 id={"#{@prefix}-revisions-title"} class="text-base font-semibold text-fg">
            Pinned revisions
          </h2>
          <p class="text-xs text-fg-muted">
            Inventory records retain the exact immutable revision they reference.
          </p>
        </div>
        <div
          :if={@catalog_type.revisions == []}
          id={"#{@prefix}-revisions-empty"}
          class="rounded-lg border border-dashed border-edge px-4 py-8 text-center text-sm text-fg-muted"
        >
          No finalized revisions are available for this catalog type.
        </div>
        <section
          :for={revision <- @catalog_type.revisions}
          id={"revision-#{revision.revision}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-line px-5 py-3">
            <div class="flex min-w-0 items-center gap-2">
              <span class="shrink-0 rounded-sm border border-edge bg-sunken px-1.5 font-mono text-[11px] text-fg-muted">
                Revision {revision.revision}
              </span>
              <h3 class="truncate font-mono text-sm font-semibold text-fg">
                {revision.part_number || "Part number not specified"}
              </h3>
            </div>
            <p class="text-xs text-fg-subtle">Immutable revision pin</p>
          </div>
          <dl
            id={"revision-#{revision.revision}-dimensions"}
            class="grid grid-cols-2 gap-4 px-5 py-4 sm:grid-cols-3 lg:grid-cols-6"
          >
            <.datum label="Rack height" value={format_measure(revision.height_units, "U")} />
            <.datum label="Width" value={format_measure(revision.width_mm, "mm")} />
            <.datum label="Depth" value={format_measure(revision.depth_mm, "mm")} />
            <.datum label="Weight" value={format_measure(revision.weight_kg, "kg")} />
            <.datum label="Airflow" value={humanize(revision.airflow)} />
            <.datum
              label="Status"
              value={if(revision.finalized_at, do: "Finalized", else: "Recorded")}
            />
          </dl>
          <div class="grid gap-6 border-t border-line px-5 py-4 lg:grid-cols-2">
            <.key_values
              id={"revision-#{revision.revision}-specifications"}
              title="Specifications"
              values={revision.specifications}
            />
            <.template_groups revision={revision} />
          </div>
        </section>
      </section>
    </article>
    """
  end

  attr :form, :map, required: true
  attr :template_errors, :map, required: true
  attr :airflow_options, :list, required: true
  attr :component_kind_options, :list, required: true

  # Module types still publish in one step, so this form stays on the page
  # beside the revisions it adds to; hardware types moved to drafts.
  defp revision_authoring_form(assigns) do
    ~H"""
    <section id="revision-authoring" class="rounded-lg border border-edge bg-surface px-5 py-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p class="text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle">
            Immutable release
          </p>
          <h2 class="mt-1 text-base font-semibold text-fg">Publish a revision</h2>
          <p class="mt-0.5 max-w-2xl text-sm text-fg-muted">
            Capture dimensions, vendor specifications, and the component blueprint. Published revisions cannot be edited.
          </p>
        </div>
        <span class="w-fit rounded-full bg-sunken px-2.5 py-0.5 text-xs font-medium text-fg-muted">
          Next revision
        </span>
      </div>

      <.form
        for={@form}
        id="new-revision-form"
        phx-change="validate_revision"
        phx-submit="publish_revision"
        aria-invalid={if(base_error_messages(@form) == [], do: nil, else: "true")}
        aria-describedby={if(base_error_messages(@form) == [], do: nil, else: "revision-form-errors")}
        class="mt-5 space-y-5"
      >
        <div
          :if={base_error_messages(@form) != []}
          id="revision-form-errors"
          role="alert"
          class="rounded-md border border-crit-line bg-crit-fill px-4 py-3 text-sm text-crit"
        >
          <p :for={error <- base_error_messages(@form)}>{error}</p>
        </div>
        <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
          <.input field={@form[:part_number]} type="text" label="Part number" />
          <.input
            field={@form[:height_units]}
            type="number"
            label="Rack height (U)"
            min="1"
            max="2147483647"
          />
          <.input
            field={@form[:width_mm]}
            type="number"
            label="Width (mm)"
            min="0.01"
            max="99999999.99"
            step="0.01"
          />
          <.input
            field={@form[:depth_mm]}
            type="number"
            label="Depth (mm)"
            min="0.01"
            max="99999999.99"
            step="0.01"
          />
          <.input
            field={@form[:weight_kg]}
            type="number"
            label="Weight (kg)"
            min="0.001"
            max="9999999.999"
            step="0.001"
          />
          <.input
            field={@form[:airflow]}
            type="select"
            label="Airflow"
            prompt="Not specified"
            options={@airflow_options}
          />
          <div class="sm:col-span-2">
            <.input
              field={@form[:specifications]}
              type="textarea"
              label="Specifications (JSON)"
              rows="3"
              spellcheck="false"
              class={json_control_class("min-h-24")}
            />
          </div>
        </div>

        <div class="border-t border-line pt-5">
          <div class="flex items-center justify-between gap-4">
            <div>
              <h3 class="text-sm font-semibold text-fg">Component templates</h3>
              <p class="mt-0.5 text-xs text-fg-muted">
                Define expected ports, bays, processors, memory, disks, and power connections.
              </p>
            </div>
            <.button
              id="add-component-template"
              type="button"
              size="sm"
              phx-click="add_component_template"
            >
              <.icon name="hero-plus-mini" class="size-4" /> Add component
            </.button>
          </div>

          <div id="component-template-fields" class="mt-4 space-y-3">
            <.inputs_for
              :let={template_form}
              field={@form[:templates]}
              default={[]}
            >
              <fieldset
                id={"component-template-field-#{template_form.params["_persistent_id"]}"}
                aria-invalid={
                  if(Map.has_key?(@template_errors, template_form.params["_persistent_id"]),
                    do: "true"
                  )
                }
                aria-describedby={
                  if(Map.has_key?(@template_errors, template_form.params["_persistent_id"]),
                    do: "component-template-field-#{template_form.params["_persistent_id"]}-errors"
                  )
                }
                class="relative rounded-lg border border-edge p-4"
              >
                <legend class="px-1 text-sm font-medium text-fg">
                  Component {template_form.index + 1}
                </legend>
                <.button
                  id={"remove-component-template-#{template_form.params["_persistent_id"]}"}
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="remove_component_template"
                  phx-value-id={template_form.params["_persistent_id"]}
                  class="absolute right-3 top-2 min-w-tap"
                  aria-label={"Remove component #{template_form.index + 1}"}
                >
                  <.icon name="hero-trash-mini" class="size-4" />
                </.button>
                <div
                  :if={Map.has_key?(@template_errors, template_form.params["_persistent_id"])}
                  id={"component-template-field-#{template_form.params["_persistent_id"]}-errors"}
                  role="alert"
                  class="mt-2 space-y-1 text-sm text-crit"
                >
                  <p :for={error <- template_error_messages(template_form, @template_errors)}>
                    Component {template_form.index + 1}: {error}
                  </p>
                </div>
                <div class="mt-3 grid gap-x-4 sm:grid-cols-2 lg:grid-cols-4">
                  <.input
                    field={template_field(template_form, :kind, @template_errors)}
                    type="select"
                    label="Kind"
                    prompt="Select kind"
                    options={@component_kind_options}
                  />
                  <.input
                    field={template_field(template_form, :name, @template_errors)}
                    type="text"
                    label="Name"
                  />
                  <.input
                    field={template_field(template_form, :label, @template_errors)}
                    type="text"
                    label="Display label"
                  />
                  <.input
                    field={template_field(template_form, :position, @template_errors)}
                    type="text"
                    label="Position"
                  />
                  <div class="sm:col-span-2">
                    <.input
                      field={template_field(template_form, :description, @template_errors)}
                      type="text"
                      label="Description"
                    />
                  </div>
                  <.input
                    field={template_field(template_form, :attributes, @template_errors)}
                    type="textarea"
                    label="Attributes (JSON)"
                    rows="2"
                    spellcheck="false"
                    class={json_control_class("min-h-20")}
                  />
                  <.input
                    field={template_field(template_form, :required, @template_errors)}
                    type="checkbox"
                    label="Required"
                  />
                </div>
              </fieldset>
            </.inputs_for>
          </div>
        </div>

        <div class="flex justify-end border-t border-line pt-4">
          <.button
            id="publish-revision"
            type="submit"
            variant="primary"
            phx-disable-with="Publishing…"
          >
            <.icon name="hero-lock-closed-mini" class="size-4" /> Publish immutable revision
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  # `<.input class=...>` replaces the default control classes, so JSON
  # textareas restate them with a monospace face for the machine values.
  defp json_control_class(min_height) do
    Enum.join(
      [
        "block w-full rounded-md border border-edge bg-surface px-3 py-2 font-mono text-xs text-fg",
        "placeholder:text-fg-subtle transition-colors focus:border-accent focus:outline-none",
        "focus:ring-4 focus:ring-ring",
        min_height
      ],
      " "
    )
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp datum(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-fg-muted">{@label}</dt>
      <dd class="mt-0.5 text-sm font-medium tabular-nums text-fg">{@value}</dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :values, :map, required: true

  defp key_values(assigns) do
    ~H"""
    <section id={@id}>
      <h4 class="text-xs font-medium text-fg-muted">{@title}</h4>
      <p :if={map_size(@values) == 0} class="mt-2 text-sm text-fg-subtle">None specified</p>
      <dl
        :if={map_size(@values) > 0}
        class="mt-2 divide-y divide-line rounded-lg border border-edge bg-sunken px-3"
      >
        <div
          :for={{key, value} <- sorted_pairs(@values)}
          class="flex items-start justify-between gap-4 py-2"
        >
          <dt class="font-mono text-xs text-fg-muted">{to_string(key)}</dt>
          <dd class="break-all text-right font-mono text-xs font-medium text-fg">
            {display_value(value)}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :revision, :map, required: true

  defp template_groups(assigns) do
    assigns =
      assign(assigns, :groups, Enum.group_by(assigns.revision.component_templates, & &1.kind))

    ~H"""
    <section id={"revision-#{@revision.revision}-templates"}>
      <h4 class="text-xs font-medium text-fg-muted">Component templates</h4>
      <p :if={map_size(@groups) == 0} class="mt-2 text-sm text-fg-subtle">
        No component templates
      </p>
      <div class="mt-2 space-y-3">
        <section
          :for={{kind, templates} <- sorted_pairs(@groups)}
          id={"revision-#{@revision.revision}-templates-#{kind}"}
          class="rounded-lg border border-edge px-4 py-3"
        >
          <h5 class="text-[10px] font-semibold uppercase tracking-[0.12em] text-fg-subtle">
            {humanize(kind)}
          </h5>
          <ul class="mt-2 divide-y divide-line">
            <li
              :for={template <- templates}
              id={"component-template-#{template.id}"}
              class="grid gap-x-3 gap-y-2 py-2 sm:grid-cols-[1fr_auto]"
            >
              <div class="min-w-0">
                <p class="font-mono text-xs font-semibold text-fg">{template.name}</p>
                <p :if={template.label} class="mt-0.5 text-sm font-medium text-fg">
                  Display label: {template.label}
                </p>
                <p :if={template.position} class="mt-0.5 text-xs text-fg-muted">
                  Position: {template.position}
                </p>
                <p :if={template.description} class="mt-1 text-xs text-fg-muted">
                  {template.description}
                </p>
              </div>
              <span class="text-xs text-fg-muted">
                {if(template.required, do: "Required", else: "Optional")}
              </span>
              <.key_values
                :if={map_size(template.attributes) > 0}
                id={"component-template-#{template.id}-attributes"}
                title="Attributes"
                values={template.attributes}
              />
            </li>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  defp create_catalog_type(socket, type, params) do
    scope = socket.assigns.current_scope
    resource_attrs = %{lifecycle_state: "active"}

    {result, route, form_key} =
      case type do
        :hardware_type ->
          attrs = %{
            manufacturer_id: params["manufacturer_id"],
            model: params["model"],
            device_class: params["device_class"],
            description: blank_to_nil(params["description"])
          }

          {Catalog.create_hardware_type(scope, resource_attrs, attrs), :hardware_type,
           :hardware_type_form}

        :module_type ->
          attrs = %{
            manufacturer_id: params["manufacturer_id"],
            model: params["model"],
            module_class: params["module_class"],
            description: blank_to_nil(params["description"])
          }

          {Catalog.create_module_type(scope, resource_attrs, attrs), :module_type,
           :module_type_form}
      end

    case result do
      {:ok, catalog_type} ->
        path =
          case route do
            :hardware_type -> ~p"/catalog/hardware-types/#{catalog_type.id}"
            :module_type -> ~p"/catalog/module-types/#{catalog_type.id}"
          end

        {:noreply,
         socket
         |> put_flash(:info, "Catalog type created")
         |> push_navigate(to: path)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form_key, catalog_form(type, params))
         |> put_flash(:error, first_error(changeset))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to author the catalog")}
    end
  end

  defp publish_revision(socket, params) do
    if socket.assigns.live_action in [:hardware_type, :module_type] do
      case revision_submission(params) do
        {:ok, revision_attrs, templates} ->
          {result, path} = publish_revision_for_type(socket, revision_attrs, templates)
          handle_revision_result(socket, params, result, path)

        {:error, revision_errors, template_errors} ->
          {:noreply,
           socket
           |> assign_revision_form(params, revision_errors, template_errors, :insert)
           |> put_flash(:error, first_submission_error(revision_errors, template_errors))}
      end
    else
      {:noreply, put_flash(socket, :error, "Revisions can only be published from a type page")}
    end
  end

  defp publish_revision_for_type(socket, revision_attrs, templates) do
    case socket.assigns.live_action do
      :hardware_type ->
        hardware_type = socket.assigns.hardware_type

        {Catalog.create_hardware_type_revision(
           socket.assigns.current_scope,
           hardware_type,
           revision_attrs,
           templates
         ), ~p"/catalog/hardware-types/#{hardware_type.id}"}

      :module_type ->
        module_type = socket.assigns.module_type

        {Catalog.create_module_type_revision(
           socket.assigns.current_scope,
           module_type,
           revision_attrs,
           templates
         ), ~p"/catalog/module-types/#{module_type.id}"}
    end
  end

  defp handle_revision_result(socket, _params, {:ok, _revision}, path) do
    {:noreply,
     socket
     |> put_flash(:info, "Immutable revision published")
     |> push_navigate(to: path)}
  end

  defp handle_revision_result(socket, params, {:error, %Ecto.Changeset{} = changeset}, _path) do
    {revision_errors, template_errors} = persistence_errors(params, changeset)

    {:noreply,
     socket
     |> assign_revision_form(params, revision_errors, template_errors, :insert)
     |> put_flash(:error, first_error(changeset))}
  end

  defp handle_revision_result(socket, _params, {:error, :forbidden}, _path) do
    {:noreply, put_flash(socket, :error, "You are not allowed to author the catalog")}
  end

  defp handle_revision_result(socket, _params, {:error, _reason}, _path) do
    {:noreply, put_flash(socket, :error, "Revision could not be published")}
  end

  defp revision_submission(params) do
    {specifications, specification_error} = decoded_json_map(params["specifications"])

    attrs = %{
      part_number: blank_to_nil(params["part_number"]),
      height_units: blank_to_nil(params["height_units"]),
      width_mm: blank_to_nil(params["width_mm"]),
      depth_mm: blank_to_nil(params["depth_mm"]),
      weight_kg: blank_to_nil(params["weight_kg"]),
      airflow: blank_to_nil(params["airflow"]),
      specifications: specifications
    }

    changeset =
      %TypeRevision{}
      |> TypeRevision.input_changeset(attrs)
      |> maybe_add_error(:specifications, specification_error)

    {templates, template_errors} = component_template_attrs(params["templates"])

    if changeset.valid? and map_size(template_errors) == 0 do
      revision = Ecto.Changeset.apply_changes(changeset)

      {:ok,
       Map.take(revision, [
         :part_number,
         :height_units,
         :width_mm,
         :depth_mm,
         :weight_kg,
         :airflow,
         :specifications
       ]), templates}
    else
      {:error, changeset.errors, template_errors}
    end
  end

  defp component_template_attrs(templates) do
    templates
    |> template_params_list()
    |> Enum.reject(&blank_template?/1)
    |> Enum.reduce({[], %{}, MapSet.new()}, fn template, {parsed, errors, identities} ->
      {attributes, attributes_error} = decoded_json_map(template["attributes"])

      attrs = %{
        kind: blank_to_nil(template["kind"]),
        name: blank_to_nil(template["name"]),
        label: blank_to_nil(template["label"]),
        position: blank_to_nil(template["position"]),
        description: blank_to_nil(template["description"]),
        required: template["required"],
        attributes: attributes
      }

      changeset =
        %ComponentTemplate{}
        |> ComponentTemplate.input_changeset(attrs)
        |> maybe_add_error(:attributes, attributes_error)
        |> maybe_add_error(:base, template["_invalid"])

      component = Ecto.Changeset.apply_changes(changeset)
      identity = component_identity(component)

      changeset =
        if identity && MapSet.member?(identities, identity) do
          Ecto.Changeset.add_error(changeset, :name, "has already been taken")
        else
          changeset
        end

      id = template["_persistent_id"]
      field_errors = changeset.errors

      parsed =
        if changeset.valid? do
          [
            Map.take(component, [
              :kind,
              :name,
              :label,
              :position,
              :description,
              :required,
              :attributes
            ])
            | parsed
          ]
        else
          parsed
        end

      errors = if field_errors == [], do: errors, else: Map.put(errors, id, field_errors)
      identities = if identity, do: MapSet.put(identities, identity), else: identities
      {parsed, errors, identities}
    end)
    |> then(fn {parsed, errors, _identities} -> {Enum.reverse(parsed), errors} end)
  end

  defp decoded_json_map(value) when value in [nil, ""], do: {%{}, nil}

  defp decoded_json_map(value) when is_binary(value) do
    case Renga.JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {decoded, nil}
      {:ok, _other} -> {%{}, "must be a JSON object"}
      {:error, _error} -> {%{}, "must contain valid JSON"}
    end
  end

  defp decoded_json_map(_value), do: {%{}, "must contain valid JSON"}

  defp reset_revision_form(socket), do: assign_revision_form(socket, default_revision_params())

  defp assign_revision_form(socket, params, errors \\ [], template_errors \\ %{}, action \\ nil) do
    socket
    |> assign(:revision_params, params)
    |> assign(:revision_form, revision_form(params, errors, action))
    |> assign(:template_errors, template_errors)
  end

  defp revision_form(params, errors \\ [], action \\ nil) do
    to_form(params, as: :revision, errors: errors, action: action)
  end

  defp normalize_revision_params(params, trusted_params) do
    trusted_ids =
      trusted_params
      |> then(fn trusted -> if is_map(trusted), do: trusted["templates"], else: nil end)
      |> template_params_list()
      |> Enum.map(& &1["_persistent_id"])

    default_revision_params()
    |> Map.merge(params)
    |> Map.update!("templates", fn templates ->
      templates
      |> template_params_list()
      |> Enum.with_index()
      |> Enum.map(fn
        {template, index} when is_map(template) ->
          default_template_params()
          |> Map.merge(Map.drop(template, ["_persistent_id", "_invalid"]))
          |> Map.put("_persistent_id", Enum.at(trusted_ids, index) || Ecto.UUID.generate())

        {_invalid, _index} ->
          Map.put(default_template_params(), "_invalid", "must be an object")
      end)
      |> index_template_params()
    end)
  end

  defp safe_revision_param_shapes?(params) do
    scalar_fields_safe?(params, @revision_scalar_fields) and
      params
      |> Map.get("templates")
      |> template_params_list()
      |> Enum.all?(fn
        template when is_map(template) -> scalar_fields_safe?(template, @template_scalar_fields)
        _invalid_template -> true
      end)
  end

  defp scalar_fields_safe?(params, fields) do
    Enum.all?(fields, fn field ->
      not Map.has_key?(params, field) or is_nil(params[field]) or is_binary(params[field])
    end)
  end

  defp template_params_list(templates) when is_map(templates) do
    templates
    |> Enum.sort_by(fn {index, _template} ->
      case Integer.parse(to_string(index)) do
        {integer, ""} -> integer
        _invalid_index -> to_string(index)
      end
    end)
    |> Enum.map(fn {_index, template} -> template end)
  end

  defp template_params_list(templates) when is_list(templates), do: templates
  defp template_params_list(_templates), do: []

  defp index_template_params(templates) do
    templates
    |> Enum.with_index()
    |> Map.new(fn {template, index} -> {Integer.to_string(index), template} end)
  end

  defp default_revision_params do
    %{
      "part_number" => "",
      "height_units" => "",
      "width_mm" => "",
      "depth_mm" => "",
      "weight_kg" => "",
      "airflow" => "",
      "specifications" => "{}",
      "templates" => %{"0" => default_template_params()}
    }
  end

  defp default_template_params do
    %{
      "_persistent_id" => Ecto.UUID.generate(),
      "kind" => "",
      "name" => "",
      "label" => "",
      "position" => "",
      "description" => "",
      "required" => "true",
      "attributes" => "{}"
    }
  end

  defp blank_template?(template) do
    is_nil(template["_invalid"]) and
      Enum.all?(~w(kind name label position description), &(template[&1] in [nil, ""])) and
      template["attributes"] in [nil, "", "{}"]
  end

  defp invalid_revision_submission(socket, action) do
    assign_revision_form(
      socket,
      socket.assigns.revision_params,
      [base: {"submission is invalid", []}],
      %{},
      action
    )
  end

  @doc false
  def persistence_errors(_params, %Ecto.Changeset{data: %TypeRevision{}, errors: errors}) do
    {errors, %{}}
  end

  def persistence_errors(
        params,
        %Ecto.Changeset{
          data: %ComponentTemplate{},
          errors: errors
        } = changeset
      ) do
    identity = changeset |> Ecto.Changeset.apply_changes() |> component_identity()

    id =
      params["templates"]
      |> template_params_list()
      |> Enum.find_value(fn template ->
        if identity && component_params_identity(template) == identity,
          do: template["_persistent_id"]
      end)

    if id, do: {[], %{id => errors}}, else: {[base: {"could not be persisted", []}], %{}}
  end

  defp component_params_identity(template) when is_map(template) do
    case {blank_to_nil(template["kind"]), blank_to_nil(template["name"])} do
      {kind, name} when is_binary(kind) and is_binary(name) and name != "" ->
        {kind, String.downcase(String.trim(name))}

      _invalid ->
        nil
    end
  end

  defp component_params_identity(_template), do: nil

  defp component_identity(%ComponentTemplate{kind: kind, name: name})
       when is_binary(kind) and is_binary(name) do
    {kind, String.downcase(name)}
  end

  defp component_identity(_component), do: nil

  defp maybe_add_error(changeset, _field, nil), do: changeset

  defp maybe_add_error(changeset, field, message),
    do: Ecto.Changeset.add_error(changeset, field, message)

  defp template_field(template_form, field, template_errors) do
    errors =
      template_errors
      |> Map.get(template_form.params["_persistent_id"], [])
      |> Keyword.get_values(field)

    %{template_form[field] | errors: errors}
  end

  defp template_error_messages(template_form, template_errors) do
    template_errors
    |> Map.get(template_form.params["_persistent_id"], [])
    |> Enum.map(&format_field_error/1)
  end

  defp base_error_messages(form) do
    form.errors
    |> Keyword.get_values(:base)
    |> Enum.map(&RengaWeb.CoreComponents.translate_error/1)
  end

  defp first_submission_error(revision_errors, template_errors) do
    case revision_errors do
      [{field, error} | _rest] ->
        format_field_error({field, error})

      [] ->
        template_errors
        |> Map.values()
        |> List.flatten()
        |> List.first()
        |> format_field_error()
    end
  end

  defp format_field_error({field, error}) do
    label = if field == :attributes, do: "Component attributes", else: humanize(field)
    "#{label} #{RengaWeb.CoreComponents.translate_error(error)}"
  end

  defp assign_manufacturer_options(socket, scope) do
    options = Enum.map(Catalog.list_manufacturers(scope), &{&1.resource.name, &1.id})
    assign(socket, :manufacturer_options, options)
  end

  defp catalog_form(type, params \\ %{})

  defp catalog_form(:manufacturer, params) do
    to_form(
      Map.merge(%{"name" => "", "slug" => "", "description" => ""}, params),
      as: :manufacturer
    )
  end

  defp catalog_form(:hardware_type, params) do
    to_form(
      Map.merge(
        %{
          "manufacturer_id" => "",
          "model" => "",
          "device_class" => "",
          "description" => ""
        },
        params
      ),
      as: :hardware_type
    )
  end

  defp catalog_form(:module_type, params) do
    to_form(
      Map.merge(
        %{
          "manufacturer_id" => "",
          "model" => "",
          "module_class" => "",
          "description" => ""
        },
        params
      ),
      as: :module_type
    )
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp first_error(changeset) do
    case Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end) do
      errors when map_size(errors) == 0 -> "Catalog entry could not be created"
      errors -> errors |> Map.values() |> List.flatten() |> List.first()
    end
  end

  defp assign_used_by(socket) do
    %{current_scope: scope, hardware_type: hardware_type} = socket.assigns
    latest = Moves.latest_revision(scope, hardware_type.id)

    assign(socket,
      latest_revision: latest,
      used_by: if(latest, do: Moves.preview(scope, hardware_type.id, latest), else: [])
    )
  end

  defp catalog_nav(action) when action in [:hardware_types, :hardware_type], do: :hardware_types
  defp catalog_nav(action) when action in [:module_types, :module_type], do: :module_types
  defp catalog_nav(:manufacturers), do: :manufacturers

  defp humanize(nil), do: "Not specified"

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_measure(nil, _unit), do: "Not specified"
  defp format_measure(value, unit), do: "#{value} #{unit}"
  defp sorted_pairs(map), do: Enum.sort_by(map, fn {key, _value} -> to_string(key) end)
  defp display_value(value), do: Renga.JSON.encode!(value)
end
