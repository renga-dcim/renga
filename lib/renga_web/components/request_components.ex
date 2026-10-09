defmodule RengaWeb.RequestComponents do
  @moduledoc """
  Member requests as the Inbox shows them: one line describing the change,
  and a panel with the effect of approving, the requester's reason, and
  the decision controls.
  """
  use RengaWeb, :html

  alias RengaWeb.Format

  @doc "What the request changes, as a short phrase: \"Lifecycle → retired\"."
  def change_summary(%{kind: "expectation"} = request), do: request.after_value["value"]

  def change_summary(request) do
    "#{change_label(request)} → #{request.after_value["value"]}"
  end

  @doc "The changed property: \"Lifecycle\" or \"Vendor override\"."
  def change_label(%{kind: "lifecycle"}), do: "Lifecycle"
  def change_label(%{kind: "owner"}), do: "Owner"
  def change_label(%{kind: "expectation"}), do: "Expected hardware"

  def change_label(%{kind: "field_override", field: field}),
    do: "#{field_label(field)} override"

  defp field_label("fqdn"), do: "FQDN"
  defp field_label(field), do: field |> Format.humanize() |> String.capitalize()

  attr :id, :string, required: true
  attr :requests, :any, required: true
  attr :row_path, :any, required: true
  attr :selected_id, :string, default: nil
  attr :empty, :string, required: true

  @doc "Requests in the shared list grammar."
  def request_table(assigns) do
    ~H"""
    <.table
      id={@id}
      rows={@requests}
      row_item={fn {_id, item} -> item end}
      row_click={fn {_id, request} -> JS.patch(@row_path.(request)) end}
      row_selected={fn {_id, request} -> request.id == @selected_id end}
      class="rounded-lg border border-edge bg-surface"
    >
      <:col :let={request} label="Change" class="min-w-0 max-w-[28rem] py-2">
        <.link
          id={"request-link-#{request.id}"}
          patch={@row_path.(request)}
          class="block rounded-sm focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-ring"
        >
          <span class="block truncate font-medium text-fg" data-request-kind={request.kind}>
            {change_summary(request)}
          </span>
          <span class="block truncate text-xs text-fg-muted">{request.reason}</span>
          <span class="block truncate text-xs text-fg-subtle sm:hidden">
            {resource_name(request.resource)} · {Format.age(request.inserted_at)}
          </span>
        </.link>
      </:col>
      <:col :let={request} label="Resource" class="hidden max-w-48 truncate sm:table-cell">
        {resource_name(request.resource)}
      </:col>
      <:col
        :let={request}
        label="Requested by"
        class="hidden max-w-48 truncate text-fg-muted sm:table-cell"
      >
        {person(request.requested_by_user)}
      </:col>
      <:col
        :let={request}
        label="Requested"
        class="hidden whitespace-nowrap text-right font-mono text-xs text-fg-muted sm:table-cell"
      >
        <span
          :if={request.status != "open"}
          data-status={request.status}
          class="mr-2 rounded-sm bg-sunken px-1.5 py-0.5 font-sans text-[11px] capitalize text-fg-muted"
        >
          {request.status}
        </span>
        <time
          datetime={DateTime.to_iso8601(request.inserted_at)}
          title={Format.datetime(request.inserted_at)}
        >
          {Format.age(request.inserted_at)}
        </time>
      </:col>
      <:empty>{@empty}</:empty>
    </.table>
    """
  end

  attr :request, :map, required: true
  attr :current_value, :any, required: true
  attr :similar, :list, required: true
  attr :similar_current, :map, required: true
  attr :can_decide?, :boolean, required: true
  attr :current_user_id, :string, required: true
  attr :decision_form, :any, required: true
  attr :on_cancel, JS, required: true

  @doc "The request panel: the effect of approving and the decision controls."
  def request_panel(assigns) do
    ~H"""
    <.side_panel
      id="request-panel"
      title={change_label(@request)}
      description={"Requested for #{resource_name(@request.resource)}"}
      show
      on_cancel={@on_cancel}
    >
      <div class="space-y-6">
        <section id="request-change" class="space-y-2 rounded-md border border-edge px-3 py-3">
          <div class="flex flex-wrap items-baseline gap-2 font-mono text-sm">
            <span class={["text-fg-muted", is_nil(@request.before_value) && "italic"]}>
              {value(@request.before_value) || "not set"}
            </span>
            <span aria-hidden="true" class="text-fg-subtle">→</span>
            <span class="sr-only">changes to</span>
            <span class="font-medium text-fg">{@request.after_value["value"]}</span>
          </div>
          <p
            :if={@request.status == "open" and @current_value != value(@request.before_value)}
            id="request-moved"
            class="text-xs text-warn-text"
          >
            <span aria-hidden="true" class="font-mono">≠</span>
            Changed since requested; it is now {@current_value || "not set"}.
          </p>
          <p class="text-xs text-fg-muted">{effect(@request)}</p>
        </section>

        <.properties id="request-properties" title="Request">
          <:item label="Resource">
            <.link navigate={~p"/inventory/#{@request.resource}"} class="text-link hover:underline">
              {resource_name(@request.resource)}
            </.link>
          </:item>
          <:item label="Requested by">{person(@request.requested_by_user)}</:item>
          <:item label="Requested">{Format.datetime(@request.inserted_at)}</:item>
          <:item label="Status">
            <span id="request-status" class="capitalize">{@request.status}</span>
          </:item>
          <:item :if={@request.decided_at} label="Decided by">
            {person(@request.decided_by_user)}
          </:item>
          <:item :if={@request.decided_at} label="Decided">
            {Format.datetime(@request.decided_at)}
          </:item>
        </.properties>

        <section aria-labelledby="request-reason-title">
          <h3 id="request-reason-title" class="mb-1 text-xs font-medium text-fg-muted">Reason</h3>
          <p id="request-reason" class="text-sm text-fg">“{@request.reason}”</p>
          <p
            :if={@request.decision_note}
            id="request-decision-note"
            class="mt-2 text-sm text-fg-muted"
          >
            Decision note: “{@request.decision_note}”
          </p>
        </section>

        <section
          :if={@request.status == "open" and @similar != []}
          id="request-similar"
          class="space-y-1.5 rounded-md border border-edge bg-sunken px-3 py-2 text-sm"
        >
          <p class="font-medium text-fg">
            The same change is requested on {similar_label(@similar)}
          </p>
          <ul class="text-xs text-fg-muted">
            <li :for={other <- @similar} id={"request-similar-#{other.id}"}>
              <p class="font-medium">{resource_name(other.resource)}</p>
              <p class="break-words font-mono">
                {value(other.before_value) || "not set"} → {other.after_value["value"]}
              </p>
              <p
                :if={@similar_current[other.id] != value(other.before_value)}
                id={"request-similar-moved-#{other.id}"}
                class="break-words text-warn-text"
              >
                Changed since requested; it is now {@similar_current[other.id] || "not set"}.
              </p>
            </li>
          </ul>
          <p :if={@can_decide?} class="text-xs text-fg-muted">
            Approving them together applies each change and closes every request.
          </p>
        </section>

        <.form
          :if={@request.status == "open" and @can_decide?}
          for={@decision_form}
          id="request-decision-form"
          phx-submit="decide"
          class="space-y-2"
        >
          <.input
            field={@decision_form[:note]}
            type="text"
            label="Note (optional)"
            autocomplete="off"
          />
          <div class="flex flex-wrap justify-end gap-2">
            <.button id="request-reject" name="decision" value="reject" variant="danger">
              Reject
            </.button>
            <.button
              :if={@similar != []}
              id="request-approve-all"
              name="decision"
              value="approve_all"
            >
              Approve all {length(@similar) + 1}
            </.button>
            <.button id="request-approve" name="decision" value="approve" variant="primary">
              Approve
            </.button>
          </div>
        </.form>

        <.button
          :if={@request.status == "open" and @request.requested_by_user_id == @current_user_id}
          id="request-withdraw"
          type="button"
          phx-click="withdraw_request"
        >
          Withdraw request
        </.button>

        <p
          :if={
            @request.status == "open" and !@can_decide? and
              @request.requested_by_user_id != @current_user_id
          }
          id="request-decision-unavailable"
          class="text-sm text-fg-muted"
        >
          Owners and admins decide requests.
        </p>
      </div>
    </.side_panel>
    """
  end

  defp effect(%{kind: "lifecycle"}),
    do: "Approving sets the resource's lifecycle. It does not control the device."

  defp effect(%{kind: "owner"}),
    do:
      "Approving makes this team the resource's owner, which takes it out of triage for ownership."

  defp effect(%{kind: "expectation"}),
    do:
      "Approving changes what this resource expects. The catalog and other resources are unchanged."

  defp effect(%{kind: "field_override"}),
    do: "Approving sets an override, which wins over every source until it is removed."

  defp similar_label([_one]), do: "1 other resource"
  defp similar_label(similar), do: "#{length(similar)} other resources"

  defp value(%{"value" => value}), do: value
  defp value(_missing), do: nil

  defp resource_name(resource), do: resource.display_name || resource.name

  defp person(%{email: email}), do: email
  defp person(_missing), do: "a former member"
end
