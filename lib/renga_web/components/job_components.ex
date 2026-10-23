defmodule RengaWeb.JobComponents do
  @moduledoc """
  Pieces that show jobs (RFD 9) the same way wherever they appear: the Jobs
  list and its detail panel, a resource's collection banner, and job entries
  in activity.

  Each state pairs a shape with its color so it reads in grayscale: a ring
  while a job waits, a spinner while an agent holds it, a filled dot once it
  ended, and a warning triangle when a person must review it.
  """
  use Phoenix.Component

  import RengaUI.CoreComponents, only: [icon: 1]

  alias Renga.Accounts.User

  alias Renga.Jobs
  alias Renga.Jobs.Job
  alias RengaWeb.Format

  @doc "The job's state as people read it."
  def state_label(%Job{state: state, cancel_requested_at: %DateTime{}})
      when state in ~w(leased running),
      do: "Cancelling"

  def state_label(%Job{state: state}), do: state_label(state)
  def state_label("queued"), do: "Waiting for agent"
  def state_label("leased"), do: "Picked up"
  def state_label("running"), do: "Running"
  def state_label("succeeded"), do: "Succeeded"
  def state_label("failed"), do: "Failed"
  def state_label("cancelled"), do: "Cancelled"
  def state_label("expired"), do: "Expired"
  def state_label("uncertain"), do: "Needs review"

  @doc "A job's state: its shape and label."
  attr :job, Job, required: true
  attr :id, :string, default: nil

  def job_state(assigns) do
    ~H"""
    <span id={@id} data-state={@job.state} class="inline-flex items-center gap-1.5">
      <.state_mark state={@job.state} />{state_label(@job)}
    </span>
    """
  end

  @doc "The shape for a job state, decorative next to its label."
  attr :state, :string, required: true
  attr :class, :string, default: "size-3.5", doc: "the icon size; dots stay small"

  def state_mark(%{state: state} = assigns) when state in ~w(leased running) do
    ~H"""
    <.icon
      name="hero-arrow-path-mini"
      class={"#{@class} shrink-0 animate-spin text-info motion-reduce:animate-none"}
    />
    """
  end

  def state_mark(%{state: "uncertain"} = assigns) do
    ~H"""
    <.icon name="hero-exclamation-triangle-mini" class={"#{@class} shrink-0 text-warn-text"} />
    """
  end

  def state_mark(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "inline-block size-2 shrink-0 rounded-full",
        @state == "queued" && "border-[1.5px] border-info",
        @state == "expired" && "border-[1.5px] border-unknown",
        @state == "succeeded" && "bg-ok",
        @state == "failed" && "bg-crit",
        @state == "cancelled" && "bg-unknown"
      ]}
    />
    """
  end

  @doc """
  One line on where the job stands or how it ended, for the Jobs list's
  Detail column. Nil when there is nothing to add to the state.
  """
  def detail(%Job{state: "queued"} = job), do: "Until #{clock(job.not_after)}"

  def detail(%Job{state: state} = job) when state in ~w(leased running) do
    cond do
      job.cancel_requested_at -> "Waiting for the agent to stop"
      job.attempts > 1 -> "Attempt #{job.attempts} of #{job.max_attempts}"
      true -> nil
    end
  end

  def detail(%Job{state: "succeeded", payload_hidden: true}), do: "Result withheld"

  def detail(%Job{state: "succeeded", result: %{"observation_id" => id}}),
    do: "Observation #{short_id(id)}"

  def detail(%Job{state: "succeeded"} = job), do: describe_result(job)
  def detail(%Job{state: "failed"} = job), do: failure(job.failure_reason)

  def detail(%Job{state: "expired", attempts: 0}), do: "No agent picked it up in time"
  def detail(%Job{state: "expired"}), do: "The agent stopped reporting"
  def detail(%Job{state: "uncertain"}), do: "Check the target and record what happened"
  def detail(%Job{}), do: nil

  @doc "Why a job failed, in words. Agent reasons are shown as they came."
  def failure("capability_not_allowed"), do: "No longer allowed in this organization"
  def failure("resolved_failed"), do: "Recorded as not taking effect"

  def failure("binding_changed"),
    do: "The resource's binding or installation key changed before it ran"

  def failure(nil), do: nil
  def failure(reason), do: reason

  defp describe_result(%Job{} = job) do
    case Renga.Jobs.Registry.fetch(Job.capability_key(job)) do
      {:ok, capability} -> capability.describe_result(job.result || %{})
      {:error, _unknown} -> "Completed"
    end
  end

  @doc "How long the agent spent on a finished job, such as `14s` or `1m 12s`."
  def took(%Job{finished_at: %DateTime{} = finished, started_at: %DateTime{} = started}),
    do: duration(DateTime.diff(finished, started))

  def took(%Job{}), do: nil

  defp duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  @doc """
  Who asked for the job: "you" for the viewer, their email for anyone else,
  and Renga for scheduled work.
  """
  def requester(%Job{requested_by_type: "system"}, _viewer_id), do: "Renga"
  def requester(%Job{requested_by_user_id: id}, id) when is_binary(id), do: "you"
  def requester(%Job{requested_by_user: %User{} = user}, _viewer_id), do: User.label(user)
  def requester(%Job{}, _viewer_id), do: "a former member"

  @doc "A wall-clock time: `06:12 UTC` today, the full date otherwise."
  def when_label(%DateTime{} = at, now \\ DateTime.utc_now()) do
    if DateTime.to_date(at) == DateTime.to_date(now),
      do: clock(at),
      else: Format.datetime(at)
  end

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M UTC")

  @doc "The first block of a UUID, enough to tell observations apart at a glance."
  def short_id(id) when is_binary(id), do: id |> String.split("-") |> hd()

  @doc """
  What a resource's last collection is doing, under its header: waiting,
  running, or how it ended, with a way to the job and, while it is open, a
  way to cancel it.
  """
  attr :job, Job, required: true
  attr :viewer_id, :string, required: true
  attr :can_cancel?, :boolean, required: true

  def collect_notice(assigns) do
    ~H"""
    <div
      id="collect-notice"
      data-state={@job.state}
      role={if(@job.state == "failed", do: "alert", else: "status")}
      class={[
        "flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border px-4 py-2.5 text-sm",
        @job.state == "failed" && "border-crit-line bg-crit-fill",
        @job.state == "uncertain" && "border-warn-line bg-warn-fill",
        @job.state not in ~w(failed uncertain) && "border-edge bg-surface"
      ]}
    >
      <.notice_mark state={@job.state} />
      <div class="min-w-0 flex-1">
        <p class="font-medium text-fg">{notice_title(@job)}</p>
        <p class="truncate text-xs text-fg-muted">
          <.notice_detail job={@job} viewer_id={@viewer_id} />
        </p>
      </div>
      <.link
        id="collect-notice-job"
        navigate={"/activity/jobs/#{@job.id}"}
        class="inline-flex min-h-tap items-center text-xs text-link hover:underline"
      >
        View job
      </.link>
      <button
        :if={@can_cancel? and Job.open?(@job) and is_nil(@job.cancel_requested_at)}
        id="collect-notice-cancel"
        type="button"
        phx-click="cancel_collect"
        phx-value-id={@job.id}
        class="inline-flex h-7 min-h-tap items-center rounded-md px-2.5 text-xs font-medium text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
      >
        Cancel
      </button>
      <button
        :if={@job.state == "expired"}
        id="collect-notice-retry"
        type="button"
        phx-click="collect"
        class="inline-flex h-7 min-h-tap items-center rounded-md border border-edge bg-surface px-2.5 text-xs font-medium text-fg transition-colors hover:bg-sunken"
      >
        Try again
      </button>
      <button
        :if={not Job.open?(@job)}
        id="collect-notice-dismiss"
        type="button"
        phx-click="dismiss_collect"
        aria-label="Dismiss"
        class="grid size-7 min-h-tap min-w-tap shrink-0 place-items-center rounded-md text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
      >
        <.icon name="hero-x-mark-mini" class="size-4" />
      </button>
    </div>
    """
  end

  attr :state, :string, required: true

  defp notice_mark(%{state: "succeeded"} = assigns),
    do: ~H|<.icon name="hero-check-circle-mini" class="size-4 shrink-0 text-ok" />|

  defp notice_mark(%{state: "failed"} = assigns),
    do: ~H|<.icon name="hero-x-circle-mini" class="size-4 shrink-0 text-crit" />|

  defp notice_mark(assigns), do: ~H|<.state_mark state={@state} class="size-4" />|

  defp notice_title(%Job{} = job) do
    noun = Jobs.noun(job)

    case job.state do
      "queued" ->
        "Waiting for the agent"

      state when state in ~w(leased running) ->
        if(job.cancel_requested_at, do: "Cancelling", else: in_progress(job))

      "succeeded" ->
        "#{noun} succeeded"

      "failed" ->
        "#{noun} failed"

      "cancelled" ->
        "#{noun} cancelled"

      "expired" ->
        "The agent didn't pick this up"

      "uncertain" ->
        "#{noun} needs review"
    end
  end

  defp in_progress(%Job{capability: "inventory.collect"}), do: "Collecting inventory"
  defp in_progress(%Job{} = job), do: "Running: #{Jobs.title(job)}"

  attr :job, Job, required: true
  attr :viewer_id, :string, required: true

  defp notice_detail(%{job: %Job{state: "queued"}} = assigns) do
    ~H"""
    It has until {clock(@job.not_after)} to pick this up · requested by {requester(
      @job,
      @viewer_id
    )}
    """
  end

  defp notice_detail(%{job: %Job{state: "leased"}} = assigns) do
    ~H"""
    Agent picked it up {ago(@job.leased_at)} · requested by {requester(@job, @viewer_id)}
    """
  end

  defp notice_detail(%{job: %Job{state: "running"}} = assigns) do
    ~H"""
    Started {ago(@job.started_at)} · requested by {requester(@job, @viewer_id)}
    """
  end

  defp notice_detail(%{job: %Job{state: "succeeded", result: %{"observation_id" => _}}} = assigns) do
    ~H"""
    {ago(@job.finished_at) |> String.capitalize()} · observation
    <span class="font-mono">{short_id(@job.result["observation_id"])}</span>
    · properties update once it is reconciled
    """
  end

  defp notice_detail(%{job: %Job{state: "expired"}} = assigns) do
    ~H"""
    {detail(@job)} before the {clock(@job.not_after)} deadline.
    """
  end

  defp notice_detail(assigns) do
    ~H"""
    {detail(@job) || "Requested by #{requester(@job, @viewer_id)}"}
    """
  end

  defp ago(nil), do: "just now"

  defp ago(%DateTime{} = at) do
    case Format.age(at) do
      "now" -> "just now"
      age -> "#{age} ago"
    end
  end

  @doc """
  A job's entry in an activity list: its shape, the sentence, and the detail
  people look for first (why it failed, which observation it produced).
  """
  attr :event, :map, required: true

  def job_change(assigns) do
    assigns = assign(assigns, :metadata, assigns.event.metadata || %{})

    ~H"""
    <span class="inline-flex min-w-0 items-center gap-1.5">
      <%= if @event.kind == "job_requested" do %>
        <.icon name="hero-play-circle-mini" class="size-3.5 shrink-0 text-fg-subtle" />
      <% else %>
        <.state_mark state={@metadata["state"]} />
      <% end %>
      <span class="truncate">
        {RengaWeb.ChangeDescription.describe(@event)}<span
          :if={change_detail(@metadata)}
          class="font-normal text-fg-muted"
        > · {change_detail(@metadata)}</span>
      </span>
    </span>
    """
  end

  defp change_detail(%{"observation_id" => id}), do: "observation #{short_id(id)}"
  defp change_detail(%{"state" => "failed", "failure_reason" => reason}), do: failure(reason)
  defp change_detail(_metadata), do: nil

  @doc "Whether a change event is a job's, so lists can render it with `job_change/1`."
  def job_change?(%{kind: kind}), do: kind in ~w(job_requested job_outcome)
end
