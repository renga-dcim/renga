defmodule RengaWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  Styling uses Tailwind CSS with Renga's design tokens (RFD 8). Components use
  the token names (`bg-surface`, `text-fg-muted`, `border-edge`, `h-control`,
  `h-row`, ...) rather than raw colors so accent, theme, and density apply
  everywhere without per-screen handling. Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * `assets/css/tokens.css` - the token values for each accent, theme,
      and density.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: RengaWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed right-4 top-4 z-50"
      {@rest}
    >
      <div class={[
        "flex w-80 max-w-[calc(100vw-2rem)] gap-3 rounded-lg border p-3 text-sm shadow-lg sm:w-96",
        @kind == :info && "border-edge bg-surface text-fg",
        @kind == :error && "border-crit-line bg-crit-fill text-fg"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-info"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="size-5 shrink-0 text-crit"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="text-pretty">{msg}</p>
        </div>
        <button
          type="button"
          class="group grid size-6 shrink-0 cursor-pointer place-items-center rounded-md"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-4 text-fg-muted group-hover:text-fg" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any, default: nil, doc: "extra classes added to the variant's classes"
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :class, button_classes(assigns.variant, assigns.size, assigns.class))

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  # Height comes from the density tokens; min-h-tap keeps a 44px target on
  # touch devices even in compact density.
  defp button_classes(variant, size, extra) do
    [
      "inline-flex min-h-tap cursor-pointer items-center justify-center gap-2 rounded-md font-medium",
      "transition-colors focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring",
      "disabled:cursor-not-allowed disabled:opacity-50 phx-submit-loading:opacity-70",
      size == "md" && "h-control px-3 text-sm",
      size == "sm" && "h-7 px-2.5 text-xs",
      variant == "primary" && "bg-accent text-accent-fg hover:bg-accent-hover",
      variant == "secondary" && "border border-edge bg-surface text-fg hover:bg-sunken",
      variant == "ghost" && "text-fg-muted hover:bg-sunken hover:text-fg",
      variant == "danger" && "bg-crit text-surface hover:opacity-90",
      extra
    ]
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :error_id, :string, default: nil
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :string, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :string, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []
    id = assigns.id || field.id
    error_id = if errors == [], do: nil, else: assigns.error_id || "#{id}-error"

    assigns
    |> assign(field: nil, id: id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign(:error_id, error_id)
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assigns
      |> assign_error_id()
      |> assign_new(:checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field mb-3">
      <label class="inline-flex min-h-tap cursor-pointer items-center gap-2 text-sm text-fg">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="inline-flex items-center gap-2">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "size-4 rounded border-edge accent-accent"}
            aria-invalid={if(@errors == [], do: nil, else: "true")}
            aria-describedby={@described_by}
            {@rest}
          />{@label}
        </span>
      </label>
      <div :if={@errors != []} id={@error_id} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign_error_id(assigns)

    ~H"""
    <div class="field mb-3">
      <label class="block">
        <span :if={@label} class={@label_class}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || [@control_class, "pr-8"],
            @errors != [] && (@error_class || @error_control_class)
          ]}
          multiple={@multiple}
          aria-invalid={if(@errors == [], do: nil, else: "true")}
          aria-describedby={@described_by}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <div :if={@errors != []} id={@error_id} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = assign_error_id(assigns)

    ~H"""
    <div class="field mb-3">
      <label class="block">
        <span :if={@label} class={@label_class}>{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || [@control_class, "h-auto min-h-20 py-2"],
            @errors != [] && (@error_class || @error_control_class)
          ]}
          aria-invalid={if(@errors == [], do: nil, else: "true")}
          aria-describedby={@described_by}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <div :if={@errors != []} id={@error_id} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    assigns = assign_error_id(assigns)

    ~H"""
    <div class="field mb-3">
      <label class="block">
        <span :if={@label} class={@label_class}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || @control_class,
            @errors != [] && (@error_class || @error_control_class)
          ]}
          aria-invalid={if(@errors == [], do: nil, else: "true")}
          aria-describedby={@described_by}
          {@rest}
        />
      </label>
      <div :if={@errors != []} id={@error_id} role="alert">
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-1.5 text-xs text-crit">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @control_class [
    "block h-control min-h-tap w-full rounded-md border border-edge bg-surface px-3 text-sm text-fg",
    "placeholder:text-fg-subtle transition-colors focus:border-accent focus:outline-none",
    "focus:ring-4 focus:ring-ring disabled:cursor-not-allowed disabled:opacity-60"
  ]

  defp assign_error_id(assigns) do
    assigns =
      if assigns.errors != [] do
        id = assigns.id || to_string(assigns.name)

        assigns
        |> assign(:id, id)
        |> assign(:error_id, assigns.error_id || "#{id}-error")
      else
        assign(assigns, :error_id, nil)
      end

    help_id = assigns.rest[:"aria-describedby"]
    description_ids = Enum.reject([help_id, assigns.error_id], &is_nil/1)
    described_by = if description_ids == [], do: nil, else: Enum.join(description_ids, " ")

    assigns
    |> assign(:rest, Map.delete(assigns.rest, :"aria-describedby"))
    |> assign(:described_by, described_by)
    |> assign(:label_class, "mb-1 block text-xs font-medium text-fg-muted")
    |> assign(:control_class, @control_class)
    |> assign(:error_control_class, "border-crit focus:border-crit focus:ring-crit-fill")
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 tracking-tight text-fg text-balance">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-fg-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders the shared list used by every collection (RFD 8, "Lists").

  Rows follow the density tokens, the header stays visible while scrolling,
  and wide tables scroll inside their own container. Rows can open an object
  with `row_navigate` and mark the open one with `row_selected`. The `:empty`
  slot shows when there are no rows, including for streams.

  With `row_navigate`, the first column becomes a native link; its slot must
  not contain other interactive controls. For streams, reinsert affected rows
  (or reset the stream) when changing selection so their markup is refreshed.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>

      <.table
        id="resources"
        rows={@streams.resources}
        row_navigate={fn {_id, resource} -> ~p"/inventory/resources/\#{resource}" end}
        row_selected={fn {_id, resource} -> resource.id == @selected_id end}
      >
        <:col :let={{_id, resource}} label="Name" class="w-1/3 font-medium">{resource.name}</:col>
        <:empty>No resources match these filters.</:empty>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_navigate, :any,
    default: nil,
    doc: "the function returning a path that clicking the row navigates to"

  attr :row_selected, :any,
    default: nil,
    doc: "the function returning whether a row is the currently open object"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  attr :class, :any, default: nil, doc: "classes for the scroll container"

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
  end

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty, doc: "the content shown when there are no rows"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    assigns =
      assign(
        assigns,
        :column_count,
        length(assigns.col) + if(assigns.action == [], do: 0, else: 1)
      )

    ~H"""
    <div class={["overflow-x-auto", @class]}>
      <table class="w-full text-left text-table text-fg">
        <thead class="sticky top-0 z-10 bg-canvas text-xs text-fg-muted">
          <tr class="h-row border-b border-edge">
            <th :for={col <- @col} scope="col" class={["px-cell font-medium", col[:class]]}>
              {col[:label]}
            </th>
            <th :if={@action != []} scope="col" class="px-cell">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :if={@empty != []} id={"#{@id}-empty"} class="hidden only:table-row">
            <td colspan={@column_count} class="px-cell py-10 text-center text-sm text-fg-muted">
              {render_slot(@empty)}
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            aria-current={@row_selected && @row_selected.(row) && "true"}
            class={[
              "h-row border-b border-line transition-colors",
              @row_selected && @row_selected.(row) && "bg-accent-tint",
              !(@row_selected && @row_selected.(row)) && "hover:bg-sunken/60"
            ]}
          >
            <td
              :for={{col, index} <- Enum.with_index(@col)}
              phx-click={
                !(index == 0 && @row_navigate) && row_command(@row_click, @row_navigate, row)
              }
              class={[
                "px-cell",
                (@row_click || @row_navigate) && "hover:cursor-pointer",
                col[:class]
              ]}
            >
              <.link
                :if={index == 0 && @row_navigate}
                navigate={@row_navigate.(row)}
                class="flex min-h-row items-center rounded-sm focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
              >
                {render_slot(col, @row_item.(row))}
              </.link>
              <%= if !(index == 0 && @row_navigate) do %>
                {render_slot(col, @row_item.(row))}
              <% end %>
            </td>
            <td :if={@action != []} class="w-0 px-cell font-medium">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp row_command(nil, nil, _row), do: nil
  defp row_command(row_click, nil, row), do: row_click.(row)
  defp row_command(_row_click, row_navigate, row), do: JS.navigate(row_navigate.(row))

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(RengaWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(RengaWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
