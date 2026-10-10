defmodule RengaWeb.FindingComponents do
  @moduledoc """
  Findings shown where the affected records live (RFD 4, "User
  interaction": address findings appear "on the affected prefix, address,
  and resource pages"). Each links to the Inbox, where people assign,
  snooze, accept exceptions, and adopt.
  """
  use RengaWeb, :html

  alias RengaWeb.Format

  @acronyms %{"vlan" => "VLAN", "vid" => "VID", "nvme" => "NVMe", "psu" => "PSU"}

  @doc "A finding kind as a label: \"missing_vlan\" -> \"Missing VLAN\"."
  def kind_label(kind) do
    kind
    |> Format.humanize()
    |> String.capitalize()
    |> String.split(" ")
    |> Enum.map_join(" ", &Map.get(@acronyms, &1, &1))
  end

  @doc """
  A compact list of findings. `show_where` adds the interface and resource,
  for pages that list findings about several of them.
  """
  attr :id, :string, required: true
  attr :findings, :list, required: true
  attr :show_where, :boolean, default: true
  attr :total, :integer, default: 0

  def finding_list(assigns) do
    ~H"""
    <ul id={@id} class="divide-y divide-line rounded-lg border border-edge bg-surface">
      <li
        :for={finding <- @findings}
        id={"#{@id}-#{finding.id}"}
        data-kind={finding.kind}
        class="flex flex-wrap items-baseline gap-x-3 gap-y-0.5 px-3 py-2 text-sm"
      >
        <.icon
          name="hero-exclamation-triangle-mini"
          class="size-4 shrink-0 self-center text-warn-text"
        />
        <.link
          navigate={~p"/inbox?#{[finding: "#{finding.domain}:#{finding.id}"]}"}
          class="font-medium text-fg hover:underline"
        >
          {kind_label(finding.kind)}
        </.link>
        <span class="min-w-0 basis-full break-words text-fg-muted sm:flex-1 sm:basis-0">
          {finding.message}
        </span>
        <span :if={@show_where} class="min-w-0 break-words font-mono text-xs text-fg-muted">
          {finding.interface_name} · {finding.resource.display_name || finding.resource.name}
        </span>
        <span
          :if={finding.state != :open}
          class="rounded-sm bg-sunken px-1.5 py-0.5 text-[11px] text-fg-muted"
        >
          {state_label(finding.state)}
        </span>
      </li>
      <li
        :if={@total > length(@findings)}
        id={"#{@id}-truncated"}
        class="px-3 py-2 text-sm text-fg-muted"
      >
        Showing first {length(@findings)} of {@total} findings.
        <.link navigate={~p"/inbox?#{[domain: "address"]}"} class="text-link hover:underline">
          View all in Inbox
        </.link>
      </li>
    </ul>
    """
  end

  defp state_label(:snoozed), do: "Snoozed"
  defp state_label(:excepted), do: "Exception"
  defp state_label(:resolved), do: "Resolved"
end
