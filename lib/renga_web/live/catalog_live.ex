defmodule RengaWeb.CatalogLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Catalog
  alias Renga.Inventory

  @device_class_options Enum.map(
                          ~w(server switch appliance chassis pdu storage other),
                          &{Phoenix.Naming.humanize(&1), &1}
                        )
  @module_class_options Enum.map(
                          ~w(line_card supervisor power_supply fan_tray transceiver other),
                          &{Phoenix.Naming.humanize(&1), &1}
                        )

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       manufacturers_empty?: true,
       hardware_types_empty?: true,
       module_types_empty?: true,
       can_manage_catalog?: Inventory.organization_manager?(socket.assigns.current_scope),
       device_class_options: @device_class_options,
       module_class_options: @module_class_options,
       manufacturer_options: [],
       manufacturer_form: catalog_form(:manufacturer),
       hardware_type_form: catalog_form(:hardware_type),
       module_type_form: catalog_form(:module_type)
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

          assign(socket,
            page_title: hardware_type.model,
            hardware_type: hardware_type
          )

        :module_types ->
          module_types = Catalog.list_module_types(scope)

          socket
          |> assign(page_title: "Module types", module_types_empty?: module_types == [])
          |> assign_manufacturer_options(scope)
          |> stream(:module_types, module_types, reset: true)

        :module_type ->
          module_type = Catalog.get_module_type!(scope, params["id"])

          assign(socket,
            page_title: module_type.model,
            module_type: module_type
          )
      end

    {:noreply, socket}
  end

  @impl true
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
         |> push_navigate(to: ~p"/dcim/manufacturers")}

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:catalog}>
      <main id="catalog-browser" class="space-y-8">
        <header class="flex flex-col gap-5 border-b border-base-content/10 pb-7 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-orange-600">
              DCIM catalog
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-base-content">
              {@page_title}
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/60">
              Organization-scoped, revision-pinned definitions for physical infrastructure.
            </p>
          </div>
          <nav
            id="catalog-navigation"
            aria-label="Catalog"
            class="flex rounded-xl bg-base-content/5 p-1"
          >
            <.link
              navigate={~p"/dcim/manufacturers"}
              class={nav_class(@live_action == :manufacturers)}
            >
              Manufacturers
            </.link>
            <.link
              navigate={~p"/dcim/hardware-types"}
              class={nav_class(@live_action in [:hardware_types, :hardware_type])}
            >
              Hardware types
            </.link>
            <.link
              navigate={~p"/dcim/module-types"}
              class={nav_class(@live_action in [:module_types, :module_type])}
            >
              Module types
            </.link>
          </nav>
        </header>

        <%= case @live_action do %>
          <% :manufacturers -> %>
            <.manufacturer_form :if={@can_manage_catalog?} form={@manufacturer_form} />
            <.manufacturer_catalog
              manufacturers={@streams.manufacturers}
              empty?={@manufacturers_empty?}
            />
          <% :hardware_types -> %>
            <.catalog_type_form
              :if={@can_manage_catalog?}
              id="new-hardware-type-form"
              form={@hardware_type_form}
              event="create_hardware_type"
              title="Add hardware type"
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
            />
          <% :module_types -> %>
            <.catalog_type_form
              :if={@can_manage_catalog?}
              id="new-module-type-form"
              form={@module_type_form}
              event="create_module_type"
              title="Add module type"
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
            />
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true

  defp manufacturer_form(assigns) do
    ~H"""
    <section class="rounded-2xl border border-orange-500/20 bg-orange-500/[0.04] p-6">
      <div>
        <h2 class="font-semibold">Add manufacturer</h2>
        <p class="mt-1 text-sm text-base-content/55">
          Create the normalized identity used by hardware and module definitions.
        </p>
      </div>
      <.form
        for={@form}
        id="new-manufacturer-form"
        phx-submit="create_manufacturer"
        class="mt-5 grid gap-4 lg:grid-cols-3"
      >
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:slug]} type="text" label="Slug" required />
        <.input field={@form[:description]} type="text" label="Description" />
        <button
          id="create-manufacturer"
          type="submit"
          phx-disable-with="Creating…"
          class="h-10 rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600 lg:col-start-3"
        >
          Create manufacturer
        </button>
      </.form>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :form, :map, required: true
  attr :event, :string, required: true
  attr :title, :string, required: true
  attr :class_label, :string, required: true
  attr :class_field, :atom, required: true
  attr :class_options, :list, required: true
  attr :manufacturer_options, :list, required: true

  defp catalog_type_form(assigns) do
    ~H"""
    <section class="rounded-2xl border border-orange-500/20 bg-orange-500/[0.04] p-6">
      <div>
        <h2 class="font-semibold">{@title}</h2>
        <p class="mt-1 text-sm text-base-content/55">
          Define the catalog identity first; immutable revisions are published from its detail page.
        </p>
      </div>
      <.form
        for={@form}
        id={@id}
        phx-submit={@event}
        class="mt-5 grid gap-4 md:grid-cols-2 xl:grid-cols-4"
      >
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
        <button
          id={"#{@id}-submit"}
          type="submit"
          phx-disable-with="Creating…"
          class="h-10 rounded-lg bg-orange-500 px-4 text-sm font-semibold text-white transition hover:bg-orange-600 xl:col-start-4"
        >
          Create type
        </button>
      </.form>
    </section>
    """
  end

  attr :manufacturers, :any, required: true
  attr :empty?, :boolean, required: true

  defp manufacturer_catalog(assigns) do
    ~H"""
    <section
      id="manufacturers-list"
      phx-update="stream"
      class="grid gap-4 md:grid-cols-2 xl:grid-cols-3"
    >
      <div
        :if={@empty?}
        id="manufacturers-empty"
        class="md:col-span-2 xl:col-span-3 rounded-2xl border border-dashed border-base-content/20 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-building-storefront" class="mx-auto size-8 text-base-content/35" />
        <h2 class="mt-4 font-semibold">No manufacturers yet</h2>
        <p class="mt-1 text-sm text-base-content/55">Catalog manufacturers will appear here.</p>
      </div>
      <article
        :for={{dom_id, manufacturer} <- @manufacturers}
        id={dom_id}
        class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-orange-500/30 hover:shadow-md"
      >
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold tracking-tight">{manufacturer.resource.name}</h2>
            <p class="mt-1 font-mono text-xs text-base-content/45">{manufacturer.slug}</p>
          </div>
          <span class="rounded-full bg-orange-500/10 px-2.5 py-1 text-xs font-medium text-orange-700">
            Manufacturer
          </span>
        </div>
        <p class="mt-5 text-sm leading-6 text-base-content/60">
          {manufacturer.description || "No manufacturer description provided."}
        </p>
        <.link
          navigate={~p"/dcim/hardware-types"}
          class="mt-5 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 hover:text-orange-700"
        >
          Browse hardware types <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </article>
    </section>
    """
  end

  attr :hardware_types, :any, required: true
  attr :empty?, :boolean, required: true

  defp hardware_type_catalog(assigns) do
    ~H"""
    <section
      id="hardware-types-list"
      phx-update="stream"
      class="grid gap-4 md:grid-cols-2 xl:grid-cols-3"
    >
      <div
        :if={@empty?}
        id="hardware-types-empty"
        class="md:col-span-2 xl:col-span-3 rounded-2xl border border-dashed border-base-content/20 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-server-stack" class="mx-auto size-8 text-base-content/35" />
        <h2 class="mt-4 font-semibold">No hardware types yet</h2>
        <p class="mt-1 text-sm text-base-content/55">
          Versioned hardware definitions will appear here.
        </p>
      </div>
      <article
        :for={{dom_id, type} <- @hardware_types}
        id={dom_id}
        class="group rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-orange-500/30 hover:shadow-md"
      >
        <p class="text-xs font-semibold uppercase tracking-wider text-orange-600">
          {humanize(type.device_class)}
        </p>
        <h2 class="mt-2 text-lg font-semibold tracking-tight">
          {type.manufacturer.resource.name} {type.model}
        </h2>
        <p class="mt-2 text-sm text-base-content/55">{type.description || type.resource.name}</p>
        <.link
          navigate={~p"/dcim/hardware-types/#{type.id}"}
          class="mt-6 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 group-hover:text-orange-700"
        >
          View revisions <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </article>
    </section>
    """
  end

  attr :module_types, :any, required: true
  attr :empty?, :boolean, required: true

  defp module_type_catalog(assigns) do
    ~H"""
    <section
      id="module-types-list"
      phx-update="stream"
      class="grid gap-4 md:grid-cols-2 xl:grid-cols-3"
    >
      <div
        :if={@empty?}
        id="module-types-empty"
        class="md:col-span-2 xl:col-span-3 rounded-2xl border border-dashed border-base-content/20 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-puzzle-piece" class="mx-auto size-8 text-base-content/35" />
        <h2 class="mt-4 font-semibold">No module types yet</h2>
        <p class="mt-1 text-sm text-base-content/55">
          Versioned installable module definitions will appear here.
        </p>
      </div>
      <article
        :for={{dom_id, type} <- @module_types}
        id={dom_id}
        class="group rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-orange-500/30 hover:shadow-md"
      >
        <p class="text-xs font-semibold uppercase tracking-wider text-orange-600">
          {humanize(type.module_class)}
        </p>
        <h2 class="mt-2 text-lg font-semibold tracking-tight">
          {type.manufacturer.resource.name} {type.model}
        </h2>
        <p class="mt-2 text-sm text-base-content/55">{type.description || type.resource.name}</p>
        <.link
          navigate={~p"/dcim/module-types/#{type.id}"}
          class="mt-6 inline-flex items-center gap-1 text-sm font-semibold text-orange-600 group-hover:text-orange-700"
        >
          View revisions <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </article>
    </section>
    """
  end

  attr :catalog_type, :map, required: true
  attr :prefix, :string, required: true
  attr :class_label, :string, required: true
  attr :class_id, :string, required: true
  attr :class_value, :string, required: true

  defp catalog_type_detail(assigns) do
    ~H"""
    <article id={"#{@prefix}-detail-#{@catalog_type.id}"} class="space-y-8">
      <section
        id={"#{@prefix}-identity"}
        class="overflow-hidden rounded-2xl border border-base-content/10 bg-base-100 shadow-sm"
      >
        <div class="grid gap-6 p-6 sm:grid-cols-[1fr_auto] sm:p-8">
          <div>
            <p class="text-sm font-medium text-orange-600">
              {@catalog_type.manufacturer.resource.name}
            </p>
            <h2 class="mt-1 text-2xl font-semibold tracking-tight">{@catalog_type.model}</h2>
            <p class="mt-3 max-w-3xl text-sm leading-6 text-base-content/60">
              {@catalog_type.description || "No type description provided."}
            </p>
          </div>
          <div class="sm:text-right">
            <p class="text-xs uppercase tracking-wider text-base-content/45">{@class_label}</p>
            <p id={@class_id} class="mt-1 font-semibold">
              {humanize(@class_value)}
            </p>
          </div>
        </div>
      </section>

      <section id={"#{@prefix}-revisions"} class="space-y-5">
        <div>
          <h2 class="text-xl font-semibold tracking-tight">Pinned revisions</h2>
          <p class="mt-1 text-sm text-base-content/55">
            Inventory records retain the exact immutable revision they reference.
          </p>
        </div>
        <div
          :if={@catalog_type.revisions == []}
          id={"#{@prefix}-revisions-empty"}
          class="rounded-2xl border border-dashed border-base-content/20 px-6 py-12 text-center text-sm text-base-content/55"
        >
          No finalized revisions are available for this catalog type.
        </div>
        <section
          :for={revision <- @catalog_type.revisions}
          id={"revision-#{revision.revision}"}
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm sm:p-8"
        >
          <div class="flex flex-col gap-4 border-b border-base-content/10 pb-6 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <span class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold text-emerald-700">
                Revision {revision.revision}
              </span>
              <h3 class="mt-3 text-lg font-semibold">
                {revision.part_number || "Part number not specified"}
              </h3>
            </div>
            <p class="text-xs text-base-content/45">Immutable revision pin</p>
          </div>
          <dl
            id={"revision-#{revision.revision}-dimensions"}
            class="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6"
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
          <div class="mt-8 grid gap-8 lg:grid-cols-2">
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

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp datum(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-base-content/45">{@label}</dt>
      <dd class="mt-1 text-sm font-semibold">{@value}</dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :values, :map, required: true

  defp key_values(assigns) do
    ~H"""
    <section id={@id}>
      <h4 class="text-sm font-semibold">{@title}</h4>
      <p :if={map_size(@values) == 0} class="mt-3 text-sm text-base-content/45">None specified</p>
      <dl
        :if={map_size(@values) > 0}
        class="mt-3 divide-y divide-base-content/10 rounded-xl bg-base-content/[0.03] px-4"
      >
        <div
          :for={{key, value} <- sorted_pairs(@values)}
          class="flex items-start justify-between gap-4 py-3 text-sm"
        >
          <dt class="text-base-content/55">{humanize(to_string(key))}</dt>
          <dd class="text-right font-mono text-xs font-medium">{display_value(value)}</dd>
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
      <h4 class="text-sm font-semibold">Component templates</h4>
      <p :if={map_size(@groups) == 0} class="mt-3 text-sm text-base-content/45">
        No component templates
      </p>
      <div class="mt-3 space-y-4">
        <section
          :for={{kind, templates} <- sorted_pairs(@groups)}
          id={"revision-#{@revision.revision}-templates-#{kind}"}
          class="rounded-xl border border-base-content/10 p-4"
        >
          <h5 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
            {humanize(kind)}
          </h5>
          <ul class="mt-3 space-y-3">
            <li
              :for={template <- templates}
              id={"component-template-#{template.id}"}
              class="flex items-start justify-between gap-4 text-sm"
            >
              <div>
                <p class="font-medium">{template.label || template.name}</p>
                <p class="text-xs text-base-content/45">{template.position || template.name}</p>
              </div>
              <span class="text-xs text-base-content/50">
                {if(template.required, do: "Required", else: "Optional")}
              </span>
            </li>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  defp create_catalog_type(socket, type, params) do
    scope = socket.assigns.current_scope
    manufacturer_name = manufacturer_name(socket.assigns.manufacturer_options, params)

    resource_attrs = %{
      name: "#{manufacturer_name} #{params["model"]}",
      display_name: "#{manufacturer_name} #{params["model"]}",
      lifecycle_state: "active"
    }

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
            :hardware_type -> ~p"/dcim/hardware-types/#{catalog_type.id}"
            :module_type -> ~p"/dcim/module-types/#{catalog_type.id}"
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

  defp assign_manufacturer_options(socket, scope) do
    options = Enum.map(Catalog.list_manufacturers(scope), &{&1.resource.name, &1.id})
    assign(socket, :manufacturer_options, options)
  end

  defp manufacturer_name(options, %{"manufacturer_id" => manufacturer_id}) do
    Enum.find_value(options, "Unknown manufacturer", fn
      {name, ^manufacturer_id} -> name
      _option -> nil
    end)
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

  defp nav_class(active?) do
    [
      "rounded-lg px-3 py-2 text-sm font-medium transition",
      if(active?,
        do: "bg-base-100 text-base-content shadow-sm",
        else: "text-base-content/55 hover:text-base-content"
      )
    ]
  end

  defp humanize(nil), do: "Not specified"

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp format_measure(nil, _unit), do: "Not specified"
  defp format_measure(value, unit), do: "#{value} #{unit}"
  defp sorted_pairs(map), do: Enum.sort_by(map, fn {key, _value} -> to_string(key) end)
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp display_value(value), do: inspect(value, limit: 20)
end
