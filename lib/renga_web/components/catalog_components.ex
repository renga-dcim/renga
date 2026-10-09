defmodule RengaWeb.CatalogComponents do
  @moduledoc """
  Catalog pieces shared outside the catalog browser's own templates: the
  "Used by" list of a hardware type, from which resources move between
  revisions in bulk (RFD 8, "Editing hardware components").
  """
  use RengaWeb, :html

  alias Renga.Catalog.Moves

  attr :entries, :list, required: true, doc: "Renga.Catalog.Moves.preview/4 entries"
  attr :latest, :any, required: true, doc: "the type's latest published revision"
  attr :selected, :any, required: true, doc: "a MapSet of selected resource ids"
  attr :auto_move, :boolean, required: true
  attr :can_move?, :boolean, required: true
  attr :can_set_auto_move?, :boolean, required: true

  @doc """
  Lists the resources using a hardware type with what moving each to the
  latest revision would change. Resources behind it can be selected, all
  that already fit with one click, and moved together after a preview.
  """
  def used_by(assigns) do
    behind = Enum.filter(assigns.entries, &behind?(&1, assigns.latest))
    chosen = Enum.filter(behind, &MapSet.member?(assigns.selected, &1.resource.id))

    assigns =
      assign(assigns,
        behind: behind,
        fitting: Enum.count(behind, &Moves.fits_entry?/1),
        chosen: chosen
      )

    ~H"""
    <section id="used-by" aria-labelledby="used-by-title" class="space-y-3">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h2 id="used-by-title" class="text-base font-semibold text-fg">Used by</h2>
        <p class="text-xs text-fg-muted">
          {length(@entries)} {plural(length(@entries), "resource")}<span :if={@latest}> · latest revision {@latest.revision}</span>
        </p>
        <button
          :if={@can_set_auto_move?}
          id="auto-move-toggle"
          type="button"
          role="switch"
          aria-checked={to_string(@auto_move)}
          phx-click="toggle_auto_move"
          class="ml-auto inline-flex min-h-tap cursor-pointer items-center gap-2 rounded-md px-2 text-sm text-fg transition-colors hover:bg-sunken"
        >
          <span class={[
            "relative inline-flex h-5 w-9 shrink-0 rounded-full transition-colors",
            if(@auto_move, do: "bg-accent", else: "bg-edge")
          ]}>
            <span class={[
              "absolute top-0.5 size-4 rounded-full bg-surface shadow transition-all",
              if(@auto_move, do: "left-4.5", else: "left-0.5")
            ]} />
          </span>
          Move automatically once they fit
        </button>
        <p :if={!@can_set_auto_move?} id="auto-move-state" class="ml-auto text-xs text-fg-muted">
          {if @auto_move,
            do: "Resources move automatically once they fit the latest revision",
            else: "Resources move only when someone moves them"}
        </p>
      </div>

      <div :if={@can_move? and @behind != []} id="bulk-move" class="flex flex-wrap items-center gap-2">
        <.button
          id="select-fitting"
          size="sm"
          phx-click="select_fitting"
          disabled={@fitting == 0}
        >
          Select the {@fitting} that already fit
        </.button>
        <.button
          :if={@chosen != []}
          id="clear-selection"
          size="sm"
          variant="ghost"
          phx-click="clear_selection"
        >
          Clear
        </.button>
        <.button
          id="move-selected"
          size="sm"
          variant="primary"
          class="ml-auto"
          disabled={@chosen == []}
          phx-click={show_overlay("bulk-move-dialog")}
        >
          Move {length(@chosen)} to revision {@latest.revision}
        </.button>
        <p :if={@chosen != []} id="bulk-move-preview" class="w-full text-xs text-fg-muted">
          {bulk_summary(@chosen)}
        </p>
      </div>

      <p
        :if={@entries == []}
        id="used-by-empty"
        class="rounded-lg border border-dashed border-edge px-4 py-8 text-center text-sm text-fg-muted"
      >
        No resource uses this hardware type yet.
      </p>
      <ul :if={@entries != []} class="divide-y divide-line rounded-lg border border-edge bg-surface">
        <li
          :for={entry <- @entries}
          id={"used-by-#{entry.resource.id}"}
          data-fits={to_string(Moves.fits_entry?(entry))}
          class="flex items-center gap-3 px-3 py-2 text-sm"
        >
          <input
            :if={@can_move? and behind?(entry, @latest)}
            type="checkbox"
            id={"used-by-#{entry.resource.id}-select"}
            checked={MapSet.member?(@selected, entry.resource.id)}
            disabled={entry.conflicts != []}
            phx-click={JS.push("toggle_used_by", value: %{id: entry.resource.id})}
            aria-label={"Select #{entry.resource.name}"}
            class="size-4 shrink-0 cursor-pointer rounded border-edge accent-accent"
          />
          <span :if={!(@can_move? and behind?(entry, @latest))} class="size-4 shrink-0" />
          <.link
            navigate={~p"/inventory/#{entry.resource}/hardware"}
            class="min-w-0 flex-1 truncate text-fg hover:underline"
          >
            {entry.resource.name}
          </.link>
          <span class="shrink-0 font-mono text-xs text-fg-muted">rev {entry.revision}</span>
          <span class="w-44 shrink-0 text-right text-xs text-fg-muted sm:w-56">
            {entry_status(entry, @latest)}
          </span>
        </li>
      </ul>
    </section>

    <.confirm_dialog
      :if={@can_move? and @chosen != []}
      id="bulk-move-dialog"
      title={"Move #{length(@chosen)} #{plural(length(@chosen), "resource")} to revision #{@latest.revision}?"}
      confirm_label="Move"
      variant="primary"
      on_confirm="move_selected"
    >
      {bulk_summary(@chosen)}
    </.confirm_dialog>
    """
  end

  defp behind?(_entry, nil), do: false
  defp behind?(entry, latest), do: entry.revision < latest.revision

  defp entry_status(entry, latest) do
    cond do
      not behind?(entry, latest) ->
        "On the latest revision"

      entry.conflicts != [] ->
        "Local names conflict with this revision"

      not entry.observed? ->
        "Not reported by a collector yet"

      Moves.fits_entry?(entry) ->
        "Fits revision #{latest.revision}"

      true ->
        difference_status(entry)
    end
  end

  defp difference_status(entry) do
    [
      entry.close > 0 && "closes #{entry.close}",
      entry.open > 0 && "opens #{entry.open}",
      (entry.close == 0 and entry.open == 0) && "no change"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
    |> String.capitalize()
  end

  defp bulk_summary(entries) do
    close = Enum.sum_by(entries, & &1.close)
    open = Enum.sum_by(entries, & &1.open)
    dropped = Enum.sum_by(entries, & &1.dropped)

    [
      "Moving them closes #{close} #{plural(close, "difference")} and opens #{open}.",
      dropped > 0 &&
        "#{dropped} local #{plural(dropped, "change")} no longer apply and will be dropped."
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
