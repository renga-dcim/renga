defmodule RengaWeb.CatalogDraftLive do
  @moduledoc """
  The draft editor for a hardware type (RFD 8, "Editing hardware
  components").

  Revision fields and specifications save to the draft as they are typed.
  Templates are edited in groups through name patterns in a side panel
  (`?group=`), with attributes as key/value rows, a preview of the names a
  pattern makes, and an explanation of how collector reports are matched
  to them. Reviewing (`?review=1`) lists what the draft changes and how the
  resources using the type compare with it before publishing. Publishing
  never moves a resource.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Catalog
  alias Renga.Catalog.ComponentMatch
  alias Renga.Catalog.Drafts
  alias Renga.Catalog.TemplatePattern
  alias Renga.Catalog.TemplatePattern.Group
  alias RengaWeb.Format

  @kinds ~w(cpu memory disk interface module_bay power_port power_outlet console_port device_bay)
  @airflows ~w(front_to_rear rear_to_front left_to_right right_to_left passive mixed)
  @text_fields ~w(part_number height_units width_mm depth_mm weight_kg airflow)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    hardware_type = Catalog.get_hardware_type!(scope, id)

    {:ok,
     socket
     |> assign(
       hardware_type: hardware_type,
       page_title: "#{hardware_type.model} draft",
       can_author?: Catalog.catalog_author?(scope),
       type_path: ~p"/catalog/hardware-types/#{hardware_type}",
       draft_path: ~p"/catalog/hardware-types/#{hardware_type}/draft",
       saved_at: nil,
       kind_options: Enum.map(@kinds, &{kind_label(&1), &1}),
       airflow_options: Enum.map(@airflows, &{Format.humanize(&1) |> String.capitalize(), &1})
     )
     |> load_draft(Drafts.get_draft(scope, hardware_type))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(group_param: params["group"], review?: params["review"] == "1")
     |> assign_group()
     |> assign_review()}
  end

  ## Draft lifecycle

  @impl true
  def handle_event("start_draft", _params, socket) do
    case Drafts.start_draft(socket.assigns.current_scope, socket.assigns.hardware_type) do
      {:ok, draft} -> {:noreply, load_draft(socket, draft)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "You cannot edit the catalog")}
    end
  end

  def handle_event("discard", _params, socket) do
    with_draft(socket, fn draft ->
      case Drafts.discard_draft(socket.assigns.current_scope, draft) do
        {:ok, :discarded} ->
          {:noreply,
           socket
           |> put_flash(:info, "Draft discarded")
           |> push_navigate(to: type_path(socket))}

        {:error, reason} ->
          closed(socket, reason)
      end
    end)
  end

  def handle_event("publish", _params, socket) do
    with_draft(socket, fn draft ->
      case Drafts.publish_draft(socket.assigns.current_scope, draft) do
        {:ok, revision} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Revision #{revision.revision} published. Resources stay on their revisions until they are moved."
           )
           |> push_navigate(to: type_path(socket))}

        {:error, reason} ->
          closed(socket, reason)
      end
    end)
  end

  ## Revision fields and specifications, saved as they change

  def handle_event("save_draft", %{"draft" => params}, socket) do
    with_draft(socket, fn draft ->
      attrs = params |> Map.take(@text_fields) |> Map.new(fn {k, v} -> {k, blank_to_nil(v)} end)

      case Drafts.update_draft(socket.assigns.current_scope, draft, attrs) do
        {:ok, draft} ->
          {:noreply, socket |> saved(draft) |> assign(:revision_form, revision_form(draft))}

        {:error, %Ecto.Changeset{errors: errors}} ->
          {:noreply, assign(socket, :revision_form, to_form(params, as: :draft, errors: errors))}

        {:error, reason} ->
          closed(socket, reason)
      end
    end)
  end

  def handle_event("save_specs", %{"specs" => params}, socket) do
    rows = rows_from_params(params)
    save_specs(assign(socket, :spec_rows, rows), rows)
  end

  def handle_event("add_spec_row", _params, socket) do
    {:noreply, update(socket, :spec_rows, &(&1 ++ [%{"key" => "", "value" => ""}]))}
  end

  def handle_event("remove_spec_row", %{"index" => index}, socket) do
    rows = List.delete_at(socket.assigns.spec_rows, to_index(index))
    save_specs(assign(socket, :spec_rows, rows), rows)
  end

  ## Template groups

  def handle_event("change_group", %{"group" => params}, socket) do
    {:noreply, assign_group_form(socket, params)}
  end

  def handle_event("add_attribute_row", _params, socket) do
    params = socket.assigns.group_params

    rows =
      rows_from_params(params["attributes"] || %{}) ++ [%{"key" => "", "value" => ""}]

    {:noreply, assign_group_form(socket, Map.put(params, "attributes", rows_to_params(rows)))}
  end

  def handle_event("remove_attribute_row", %{"index" => index}, socket) do
    params = socket.assigns.group_params

    rows =
      (params["attributes"] || %{})
      |> rows_from_params()
      |> List.delete_at(to_index(index))

    {:noreply, assign_group_form(socket, Map.put(params, "attributes", rows_to_params(rows)))}
  end

  def handle_event("save_group", %{"group" => params}, socket) do
    with_draft(socket, fn draft ->
      attrs = %{
        "kind" => params["kind"],
        "name_pattern" => params["name_pattern"],
        "position_pattern" => params["position_pattern"],
        "required" => params["required"] == "true",
        "label" => blank_to_nil(params["label"]),
        "attributes" => rows_to_map(rows_from_params(params["attributes"] || %{}))
      }

      replacing = Enum.map(selected_templates(socket), & &1.id)

      case Drafts.put_template_group(socket.assigns.current_scope, draft, replacing, attrs) do
        {:ok, draft} ->
          {:noreply,
           socket
           |> saved(draft)
           |> load_draft(draft)
           |> push_patch(to: draft_path(socket))}

        {:error, message} when is_binary(message) ->
          errors = [name_pattern: {message, []}]
          {:noreply, assign_group_form(socket, params, errors)}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = [name_pattern: {changeset_message(changeset), []}]
          {:noreply, assign_group_form(socket, params, errors)}

        {:error, reason} ->
          closed(socket, reason)
      end
    end)
  end

  def handle_event("delete_group", _params, socket) do
    with_draft(socket, fn draft ->
      ids = Enum.map(selected_templates(socket), & &1.id)

      case Drafts.delete_templates(socket.assigns.current_scope, draft, ids) do
        {:ok, draft} ->
          {:noreply,
           socket
           |> saved(draft)
           |> load_draft(draft)
           |> push_patch(to: draft_path(socket))}

        {:error, reason} ->
          closed(socket, reason)
      end
    end)
  end

  defp save_specs(socket, rows) do
    with_draft(socket, fn draft ->
      case Drafts.update_draft(socket.assigns.current_scope, draft, %{
             "specifications" => rows_to_map(rows)
           }) do
        {:ok, draft} -> {:noreply, saved(socket, draft)}
        {:error, %Ecto.Changeset{}} -> {:noreply, put_flash(socket, :error, "Check the values")}
        {:error, reason} -> closed(socket, reason)
      end
    end)
  end

  # Writes need an open draft and an author; anything else is a stale or
  # forged event and changes nothing.
  defp with_draft(socket, fun) do
    if socket.assigns.can_author? and socket.assigns.draft,
      do: fun.(socket.assigns.draft),
      else: {:noreply, socket}
  end

  defp closed(socket, :forbidden),
    do: {:noreply, put_flash(socket, :error, "You cannot edit the catalog")}

  defp closed(socket, _reason) do
    {:noreply,
     socket
     |> put_flash(:error, "This draft was published or discarded elsewhere")
     |> push_navigate(to: type_path(socket))}
  end

  defp saved(socket, draft),
    do: assign(socket, draft: draft, saved_at: DateTime.utc_now())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:hardware_types}
      content_class="p-0"
    >
      <.object_page
        id="catalog-draft"
        title={@hardware_type.model}
        subtitle={
          if(@draft,
            do: "Draft revision #{@draft.revision}",
            else: @hardware_type.manufacturer.resource.name
          )
        }
      >
        <:breadcrumb>
          <.link navigate={~p"/catalog/hardware-types"} class="hover:text-fg">Hardware types</.link>
          <span aria-hidden="true">/</span>
          <.link navigate={@type_path} class="hover:text-fg">{@hardware_type.model}</.link>
          <span aria-hidden="true">/</span>
          <span class="text-fg">Draft</span>
        </:breadcrumb>
        <:icon><.icon name="hero-pencil-square" class="size-5" /></:icon>
        <:actions :if={@draft && @can_author?}>
          <span
            id="draft-saved"
            class={["mr-2 text-xs text-fg-muted", !@saved_at && "hidden sm:inline"]}
            aria-live="polite"
          >
            {if @saved_at, do: "Saved", else: "Changes save as you type"}
          </span>
          <.button
            id="draft-discard"
            size="sm"
            variant="ghost"
            phx-click={show_overlay("discard-dialog")}
          >
            Discard
          </.button>
          <.button
            id="draft-review"
            size="sm"
            variant="primary"
            class="whitespace-nowrap"
            patch={"#{@draft_path}?review=1"}
          >
            Review and publish
          </.button>
        </:actions>

        <%= cond do %>
          <% @draft && @can_author? -> %>
            <div id="draft-editor" class="space-y-8">
              <.revision_section form={@revision_form} airflow_options={@airflow_options} />
              <.specs_section rows={@spec_rows} />
              <.templates_section groups={@groups} draft_path={@draft_path} />
            </div>
          <% @can_author? -> %>
            <div
              id="draft-none"
              class="rounded-lg border border-dashed border-edge px-4 py-10 text-center"
            >
              <p class="text-sm text-fg-muted">No draft is open for this hardware type.</p>
              <.button id="draft-start" class="mt-4" variant="primary" phx-click="start_draft">
                Start a draft
              </.button>
            </div>
          <% true -> %>
            <p id="draft-read-only" class="text-sm text-fg-muted">
              Owners, admins, and members edit the catalog.
            </p>
        <% end %>
      </.object_page>

      <.group_panel
        :if={@draft && @can_author? && @group_param}
        form={@group_form}
        rows={@attribute_rows}
        preview={@group_preview}
        explanation={@group_explanation}
        existing?={@group_param != "new"}
        kind_options={@kind_options}
        close_path={@draft_path}
      />

      <.review_panel
        :if={@draft && @can_author? && @review?}
        changes={@changes}
        impact={@impact}
        close_path={@draft_path}
      />

      <.confirm_dialog
        :if={@draft && @can_author?}
        id="discard-dialog"
        title="Discard this draft?"
        confirm_label="Discard draft"
        on_confirm="discard"
      >
        Every change in it is lost. Published revisions are unchanged.
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :airflow_options, :list, required: true

  defp revision_section(assigns) do
    ~H"""
    <section id="draft-revision" aria-labelledby="draft-revision-title" class="space-y-3">
      <h2 id="draft-revision-title" class="text-sm font-semibold text-fg">Revision</h2>
      <.form
        for={@form}
        id="draft-form"
        phx-change="save_draft"
        class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-3"
      >
        <.input field={@form[:part_number]} label="Part number" phx-debounce="500" />
        <.input field={@form[:height_units]} type="number" label="Height (U)" phx-debounce="500" />
        <.input
          field={@form[:airflow]}
          type="select"
          label="Airflow"
          prompt="Not specified"
          options={@airflow_options}
        />
        <.input field={@form[:width_mm]} label="Width (mm)" inputmode="decimal" phx-debounce="500" />
        <.input field={@form[:depth_mm]} label="Depth (mm)" inputmode="decimal" phx-debounce="500" />
        <.input
          field={@form[:weight_kg]}
          label="Weight (kg)"
          inputmode="decimal"
          phx-debounce="500"
        />
      </.form>
    </section>
    """
  end

  attr :rows, :list, required: true

  defp specs_section(assigns) do
    ~H"""
    <section id="draft-specs" aria-labelledby="draft-specs-title" class="space-y-3">
      <div class="flex items-baseline gap-3">
        <h2 id="draft-specs-title" class="text-sm font-semibold text-fg">Specifications</h2>
        <p class="text-xs text-fg-muted">Vendor facts about the model, one per row</p>
      </div>
      <.form for={%{}} as={:specs} id="specs-form" phx-change="save_specs">
        <.key_value_rows id="specs" rows={@rows} name="specs" remove_event="remove_spec_row" />
      </.form>
      <.button id="add-spec-row" size="sm" variant="ghost" phx-click="add_spec_row">
        <.icon name="hero-plus-mini" class="size-4" /> Add specification
      </.button>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :name, :string, required: true
  attr :remove_event, :string, required: true

  # Attributes as rows rather than JSON: numbers and true/false are stored
  # as such, so they compare by value with what collectors report.
  defp key_value_rows(assigns) do
    ~H"""
    <div id={"#{@id}-rows"} class="space-y-1.5">
      <p :if={@rows == []} class="text-sm text-fg-subtle">None yet.</p>
      <div
        :for={{row, index} <- Enum.with_index(@rows)}
        id={"#{@id}-row-#{index}"}
        class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] items-center gap-2"
      >
        <input
          type="text"
          name={"#{@name}[#{index}][key]"}
          value={row["key"]}
          placeholder="key"
          aria-label="Key"
          autocomplete="off"
          phx-debounce="500"
          class="h-9 min-w-0 rounded-md border border-edge bg-surface px-2.5 font-mono text-sm text-fg focus:border-accent focus:outline-none focus:ring-4 focus:ring-ring"
        />
        <input
          type="text"
          name={"#{@name}[#{index}][value]"}
          value={row["value"]}
          placeholder="value"
          aria-label={"Value for #{row["key"]}"}
          autocomplete="off"
          phx-debounce="500"
          class="h-9 min-w-0 rounded-md border border-edge bg-surface px-2.5 font-mono text-sm text-fg focus:border-accent focus:outline-none focus:ring-4 focus:ring-ring"
        />
        <button
          type="button"
          id={"#{@id}-row-#{index}-remove"}
          phx-click={JS.push(@remove_event, value: %{index: index})}
          aria-label={"Remove #{row["key"]}"}
          class="grid min-h-tap size-9 cursor-pointer place-items-center rounded-md text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :groups, :list, required: true
  attr :draft_path, :string, required: true

  defp templates_section(assigns) do
    ~H"""
    <section id="draft-templates" aria-labelledby="draft-templates-title" class="space-y-3">
      <div class="flex flex-wrap items-baseline gap-3">
        <h2 id="draft-templates-title" class="text-sm font-semibold text-fg">Component templates</h2>
        <p class="text-xs text-fg-muted">
          {template_count(@groups)} templates in {length(@groups)} groups
        </p>
        <.button
          id="add-template-group"
          size="sm"
          class="ml-auto"
          patch={"#{@draft_path}?group=new"}
        >
          <.icon name="hero-plus-mini" class="size-4" /> Add templates
        </.button>
      </div>
      <p
        :if={@groups == []}
        id="draft-templates-empty"
        class="rounded-lg border border-dashed border-edge px-4 py-8 text-center text-sm text-fg-muted"
      >
        No templates yet. Add a group like <span class="font-mono text-fg">DIMM {"{A,B}{1..16}"}</span>.
      </p>
      <ul class="divide-y divide-line rounded-lg border border-edge bg-surface">
        <li :for={group <- @groups} id={"group-#{hd(group.templates).id}"}>
          <.link
            patch={"#{@draft_path}?group=#{hd(group.templates).id}"}
            class="grid gap-x-4 gap-y-1 px-3 py-2.5 text-sm transition-colors hover:bg-sunken/60 focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-inset focus-visible:ring-ring sm:grid-cols-[7rem_minmax(0,1fr)_auto]"
          >
            <span class="text-xs text-fg-muted">{kind_label(group.kind)}</span>
            <span class="min-w-0">
              <span class="block truncate font-mono text-fg">{group.name_pattern}</span>
              <span class="block truncate text-xs text-fg-muted">
                {length(group.templates)} {if length(group.templates) == 1,
                  do: "template",
                  else: "templates"}<span :if={group.position_pattern}> · slot <span class="font-mono">{group.position_pattern}</span></span>
                <span :if={!group.required}> · optional</span>
              </span>
              <span :if={group.attributes != %{}} class="mt-1 flex flex-wrap gap-1">
                <span
                  :for={{key, value} <- Enum.sort(group.attributes)}
                  class="rounded bg-sunken px-1.5 py-0.5 font-mono text-[11px] text-fg-muted"
                >
                  {key}={format_value(value)}
                </span>
              </span>
            </span>
            <span class="hidden self-center text-xs text-link sm:block">Edit</span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :rows, :list, required: true
  attr :preview, :any, required: true
  attr :explanation, :list, required: true
  attr :existing?, :boolean, required: true
  attr :kind_options, :list, required: true
  attr :close_path, :string, required: true

  defp group_panel(assigns) do
    ~H"""
    <.side_panel
      id="group-panel"
      title={if @existing?, do: "Edit templates", else: "Add templates"}
      description="One pattern stands for many templates"
      show
      on_cancel={JS.patch(@close_path)}
    >
      <.form for={@form} id="group-form" phx-change="change_group" phx-submit="save_group">
        <.input field={@form[:kind]} type="select" label="Kind" options={@kind_options} />
        <.input
          field={@form[:name_pattern]}
          label="Names"
          placeholder="DIMM {A,B}{1..16}"
          autocomplete="off"
          phx-debounce="300"
          class="w-full rounded-md border border-edge bg-surface px-2.5 py-2 font-mono text-sm text-fg"
        />
        <p id="group-preview" class="-mt-1 mb-3 text-xs text-fg-muted">
          <%= case @preview do %>
            <% {:ok, slots} -> %>
              {length(slots)} {if length(slots) == 1, do: "template", else: "templates"}: {preview_names(
                slots
              )}
            <% {:error, message} -> %>
              <span class="text-crit">{message}</span>
          <% end %>
        </p>
        <.input
          field={@form[:position_pattern]}
          label="Slots (optional)"
          placeholder="Taken from the end of each name"
          autocomplete="off"
          phx-debounce="300"
          class="w-full rounded-md border border-edge bg-surface px-2.5 py-2 font-mono text-sm text-fg"
        />
        <.input field={@form[:required]} type="checkbox" label="Required" />

        <fieldset class="mt-4 space-y-2">
          <legend class="text-xs font-medium text-fg-muted">Attributes</legend>
          <.key_value_rows
            id="attributes"
            rows={@rows}
            name="group[attributes]"
            remove_event="remove_attribute_row"
          />
          <.button
            id="add-attribute-row"
            type="button"
            size="sm"
            variant="ghost"
            phx-click="add_attribute_row"
          >
            <.icon name="hero-plus-mini" class="size-4" /> Add attribute
          </.button>
        </fieldset>

        <section id="group-explanation" class="mt-4 space-y-1 rounded-md bg-sunken px-3 py-2">
          <h3 class="text-xs font-medium text-fg-muted">How reports match</h3>
          <p :for={sentence <- @explanation} class="text-sm text-fg-muted">{sentence}</p>
        </section>
      </.form>
      <:footer>
        <.button
          :if={@existing?}
          id="group-delete"
          type="button"
          variant="ghost"
          class="mr-auto"
          phx-click="delete_group"
        >
          Remove templates
        </.button>
        <.button id="group-save" variant="primary" form="group-form" phx-disable-with="Saving…">
          Save to draft
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  attr :changes, :map, required: true
  attr :impact, :list, required: true
  attr :close_path, :string, required: true

  defp review_panel(assigns) do
    fitting = Enum.count(assigns.impact, &Drafts.fits?/1)
    assigns = assign(assigns, fitting: fitting, nothing?: nothing_changed?(assigns.changes))

    ~H"""
    <.side_panel
      id="review-panel"
      title="Review and publish"
      description={
        if(@changes.base,
          do: "Compared with revision #{@changes.base.revision}",
          else: "The first revision of this type"
        )
      }
      show
      on_cancel={JS.patch(@close_path)}
    >
      <div class="space-y-6">
        <section id="review-changes" aria-labelledby="review-changes-title" class="space-y-2">
          <h3 id="review-changes-title" class="text-xs font-medium text-fg-muted">Changes</h3>
          <p :if={@nothing?} class="text-sm text-fg-muted">Nothing changed yet.</p>
          <ul class="space-y-1.5 text-sm">
            <li
              :for={{field, old, new} <- @changes.fields}
              id={"change-field-#{field}"}
              class="flex gap-2"
            >
              <.icon name="hero-pencil-square-mini" class="mt-0.5 size-4 shrink-0 text-warn-text" />
              <.value_change
                label={field_label(field)}
                old={field_value(field, old)}
                new={field_value(field, new)}
              />
            </li>
            <li
              :for={{key, old, new} <- @changes.specifications}
              id={"change-spec-#{key}"}
              class="flex gap-2"
            >
              <.icon name="hero-pencil-square-mini" class="mt-0.5 size-4 shrink-0 text-warn-text" />
              <.value_change label={key} old={format_value(old)} new={format_value(new)} mono_label />
            </li>
            <li :for={group <- @changes.added} class="flex gap-2" data-change="added">
              <.icon name="hero-plus-circle-mini" class="mt-0.5 size-4 shrink-0 text-ok" />
              <span>
                Adds <span class="font-mono">{group.name_pattern}</span> ({length(group.templates)})
              </span>
            </li>
            <li :for={group <- @changes.removed} class="flex gap-2" data-change="removed">
              <.icon name="hero-minus-circle-mini" class="mt-0.5 size-4 shrink-0 text-crit" />
              <span>
                Removes <span class="font-mono">{group.name_pattern}</span>
                ({length(group.templates)})
              </span>
            </li>
            <li :for={{group, fields} <- @changes.changed} class="flex gap-2" data-change="changed">
              <.icon name="hero-pencil-square-mini" class="mt-0.5 size-4 shrink-0 text-warn-text" />
              <span>
                Changes {Enum.map_join(fields, ", ", &field_label/1)} of
                <span class="font-mono">{group.name_pattern}</span>
              </span>
            </li>
          </ul>
        </section>

        <section id="review-impact" aria-labelledby="review-impact-title" class="space-y-2">
          <h3 id="review-impact-title" class="text-xs font-medium text-fg-muted">
            Resources using this type
          </h3>
          <p :if={@impact == []} class="text-sm text-fg-muted">No resource uses this type yet.</p>
          <p :if={@impact != []} id="review-impact-summary" class="text-sm text-fg">
            {length(@impact)} {if length(@impact) == 1, do: "resource", else: "resources"};
            <span class="font-mono">{@fitting}</span>
            would match this draft as they are.
            Publishing moves none of them.
          </p>
          <ul :if={@impact != []} class="divide-y divide-line rounded-lg border border-edge">
            <li
              :for={entry <- @impact}
              id={"impact-#{entry.resource.id}"}
              data-fits={to_string(Drafts.fits?(entry))}
              class="grid grid-cols-[minmax(0,1fr)_auto] gap-x-3 px-3 py-2 text-sm"
            >
              <span class="truncate">{entry.resource.name}</span>
              <span class="text-xs text-fg-muted">rev {entry.revision}</span>
              <span class="col-span-2 text-xs text-fg-muted">
                <%= cond do %>
                  <% !entry.observed? -> %>
                    Not reported by a collector yet
                  <% Drafts.fits?(entry) -> %>
                    <span class="text-ok">Matches the draft</span>
                    · {differences(entry.current)} differences now
                  <% true -> %>
                    {differences(entry.current)} differences now → {differences(entry.draft)} on the draft
                <% end %>
              </span>
            </li>
          </ul>
        </section>
      </div>
      <:footer>
        <.button
          id="review-publish"
          variant="primary"
          phx-click="publish"
          phx-disable-with="Publishing…"
        >
          Publish revision
        </.button>
      </:footer>
    </.side_panel>
    """
  end

  attr :label, :string, required: true
  attr :old, :string, default: nil
  attr :new, :string, default: nil
  attr :mono_label, :boolean, default: false

  defp value_change(assigns) do
    ~H"""
    <span class="min-w-0 break-words">
      <span class={@mono_label && "font-mono"}>{@label}</span>:
      <%= cond do %>
        <% is_nil(@old) -> %>
          set to <span class="font-mono">{@new}</span>
        <% is_nil(@new) -> %>
          <span class="font-mono text-fg-muted line-through">{@old}</span> removed
        <% true -> %>
          <span class="font-mono text-fg-muted line-through">{@old}</span>
          → <span class="font-mono">{@new}</span>
      <% end %>
    </span>
    """
  end

  ## Loading

  defp load_draft(socket, nil),
    do: assign(socket, draft: nil, groups: [], spec_rows: [], revision_form: nil)

  defp load_draft(socket, draft) do
    assign(socket,
      draft: draft,
      groups: TemplatePattern.compress(draft.component_templates),
      spec_rows: map_to_rows(draft.specifications),
      revision_form: revision_form(draft)
    )
  end

  defp revision_form(draft) do
    draft
    |> Map.take(Enum.map(@text_fields, &String.to_existing_atom/1))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), format_value(value) || ""} end)
    |> to_form(as: :draft)
  end

  defp assign_group(%{assigns: %{group_param: nil}} = socket),
    do: assign(socket, group_form: nil, group_params: %{}, attribute_rows: [])

  defp assign_group(socket) do
    case selected_group(socket) do
      %Group{} = group ->
        assign_group_form(socket, %{
          "kind" => group.kind,
          "name_pattern" => group.name_pattern,
          "position_pattern" => explicit_position_pattern(group),
          "required" => to_string(group.required),
          "label" => group.label || "",
          "attributes" => group.attributes |> map_to_rows() |> rows_to_params()
        })

      nil ->
        assign_group_form(socket, %{
          "kind" => "memory",
          "name_pattern" => "",
          "position_pattern" => "",
          "required" => "true",
          "attributes" => %{}
        })
    end
  end

  defp assign_group_form(socket, params, errors \\ []) do
    rows = rows_from_params(params["attributes"] || %{})
    preview = TemplatePattern.expand_slots(params["name_pattern"], params["position_pattern"])

    explanation =
      ComponentMatch.explain(%{
        kind: params["kind"],
        name: blank_to_nil(params["name_pattern"]) || "the name",
        position:
          case preview do
            {:ok, [{_name, nil} | _rest]} ->
              nil

            _slots ->
              blank_to_nil(params["position_pattern"]) || slot_hint(params["name_pattern"])
          end,
        attributes: rows_to_map(rows)
      })

    assign(socket,
      group_params: params,
      group_form: to_form(params, as: :group, errors: errors),
      attribute_rows: rows,
      group_preview: preview,
      group_explanation: explanation
    )
  end

  # Slots that follow from the names stay blank in the form, so editing
  # the names keeps them in step.
  defp explicit_position_pattern(%Group{position_pattern: nil}), do: ""

  defp explicit_position_pattern(%Group{} = group) do
    if TemplatePattern.expand_slots(group.name_pattern) ==
         TemplatePattern.expand_slots(group.name_pattern, group.position_pattern),
       do: "",
       else: group.position_pattern
  end

  # The slot a group's names end in, for the explanation: "{A,B}{1..16}"
  # for "DIMM {A,B}{1..16}".
  defp slot_hint(pattern) do
    case Regex.run(~r/((?:\{[^{}]*\}|[A-Za-z])*(?:\{[^{}]*\}|\d+))$/, pattern || "") do
      [_match, slot] -> slot
      nil -> nil
    end
  end

  defp selected_group(%{assigns: %{group_param: id, groups: groups}}) do
    Enum.find(groups, fn group -> Enum.any?(group.templates, &(&1.id == id)) end)
  end

  defp selected_templates(socket) do
    case selected_group(socket) do
      %Group{templates: templates} -> templates
      nil -> []
    end
  end

  defp assign_review(%{assigns: %{review?: true, draft: draft}} = socket)
       when not is_nil(draft) do
    scope = socket.assigns.current_scope
    assign(socket, changes: Drafts.change_list(scope, draft), impact: Drafts.impact(scope, draft))
  end

  defp assign_review(socket), do: assign(socket, changes: nil, impact: [])

  ## Key/value rows

  defp rows_from_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {index, _row} -> to_index(index) end)
    |> Enum.map(fn {_index, row} ->
      %{"key" => row["key"] || "", "value" => row["value"] || ""}
    end)
  end

  defp rows_from_params(_params), do: []

  # Click values arrive as numbers from the browser and as text from forms.
  defp to_index(index) when is_integer(index), do: index
  defp to_index(index) when is_binary(index), do: String.to_integer(index)

  defp rows_to_params(rows) do
    rows |> Enum.with_index() |> Map.new(fn {row, index} -> {Integer.to_string(index), row} end)
  end

  defp rows_to_map(rows) do
    rows
    |> Enum.reject(&(String.trim(&1["key"]) == ""))
    |> Map.new(&{String.trim(&1["key"]), parse_value(&1["value"])})
  end

  defp map_to_rows(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => format_value(value) || ""} end)
  end

  # Values keep their JSON type so they compare by value with collector
  # reports: 64 is a number, not the text "64".
  defp parse_value(value) do
    value = String.trim(value || "")

    cond do
      value in ~w(true false) -> value == "true"
      Regex.match?(~r/^-?\d+$/, value) -> String.to_integer(value)
      Regex.match?(~r/^-?\d+\.\d+$/, value) -> Decimal.new(value)
      true -> value
    end
  end

  ## Presentation

  defp type_path(socket), do: socket.assigns.type_path
  defp draft_path(socket), do: socket.assigns.draft_path

  defp preview_names(slots) do
    names = Enum.map(slots, &elem(&1, 0))

    if length(names) > 4,
      do: "#{Enum.at(names, 0)}, #{Enum.at(names, 1)}, … #{List.last(names)}",
      else: Enum.join(names, ", ")
  end

  defp template_count(groups), do: Enum.sum_by(groups, &length(&1.templates))

  defp differences(counts), do: counts.missing + counts.not_expected + counts.local_change

  defp nothing_changed?(changes) do
    Enum.all?([:fields, :specifications, :added, :removed, :changed], &(changes[&1] == []))
  end

  defp field_value(:airflow, value) when is_binary(value),
    do: value |> Format.humanize() |> String.capitalize()

  defp field_value(_field, value), do: format_value(value)

  defp changeset_message(%Ecto.Changeset{errors: [{field, {message, _opts}} | _rest]}),
    do: "#{field} #{message}"

  defp changeset_message(_changeset), do: "These templates could not be saved"

  defp kind_label("cpu"), do: "CPU"
  defp kind_label(kind), do: kind |> Format.humanize() |> String.capitalize()

  defp field_label(:height_units), do: "Height (U)"
  defp field_label(:width_mm), do: "Width (mm)"
  defp field_label(:depth_mm), do: "Depth (mm)"
  defp field_label(:weight_kg), do: "Weight (kg)"
  defp field_label(field), do: field |> Format.humanize() |> String.capitalize()

  defp format_value(nil), do: nil
  defp format_value(value) when is_binary(value), do: value
  defp format_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_value(value), do: Renga.JSON.encode!(value)

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
end
