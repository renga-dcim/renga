defmodule RengaWeb.TargetBindingComponents do
  @moduledoc """
  The resource's trusted target for privileged jobs (RFD 13, "Trusted
  privileged targets"). Owners and admins bind the resource to one
  installation that reports it and holds an approved key, comparing the
  key's fingerprint as they do; everyone else sees the binding.
  """
  use RengaWeb, :html

  alias RengaWeb.Format

  attr :binding, :any, required: true
  attr :candidates, :list, required: true
  attr :can_manage?, :boolean, required: true

  def target_binding(assigns) do
    ~H"""
    <section id="target-binding" aria-labelledby="target-binding-title">
      <h2 id="target-binding-title" class="mb-1 text-sm font-semibold text-fg">
        Privileged jobs
      </h2>
      <p class="mb-2 text-xs text-fg-muted">
        Restarts and terminals run only on the installation bound here, and only with its
        approved key.
      </p>

      <div
        :if={@binding}
        id="target-binding-current"
        class="flex flex-wrap items-baseline gap-x-3 gap-y-1 rounded-lg border border-edge bg-surface px-4 py-2.5 text-sm"
      >
        <span class="font-medium text-fg">{@binding.agent.name}</span>
        <span class="font-mono text-xs text-fg-muted" title={@binding.installation_key.fingerprint}>
          {short_fingerprint(@binding.installation_key.fingerprint)}
        </span>
        <span class="text-xs text-fg-muted">
          Version {@binding.version}, bound {Format.age(@binding.approved_at)}
        </span>
        <button
          :if={@can_manage?}
          id="revoke-target-binding-button"
          type="button"
          phx-click={show_overlay("revoke-target-binding")}
          class="ml-auto min-h-tap min-w-tap cursor-pointer text-xs text-crit hover:underline"
        >
          Unbind
        </button>
      </div>

      <p
        :if={is_nil(@binding)}
        id="target-binding-none"
        class="rounded-lg border border-edge bg-surface px-4 py-3 text-sm text-fg-muted"
      >
        Not bound. Privileged jobs cannot run on this resource.
      </p>

      <ul
        :if={@can_manage? and other_candidates(@candidates, @binding) != []}
        id="target-binding-candidates"
        class="mt-2 divide-y divide-line rounded-lg border border-edge bg-surface"
      >
        <li
          :for={{agent, key} <- other_candidates(@candidates, @binding)}
          id={"target-candidate-#{agent.id}"}
          class="flex flex-wrap items-baseline gap-x-3 gap-y-1 px-4 py-2.5 text-sm"
        >
          <span class="text-fg">{agent.name}</span>
          <span class="font-mono text-xs text-fg-muted" title={key.fingerprint}>
            {short_fingerprint(key.fingerprint)}
          </span>
          <button
            id={"bind-target-#{agent.id}-button"}
            type="button"
            phx-click={show_overlay("bind-target-#{agent.id}")}
            class="ml-auto min-h-tap min-w-tap cursor-pointer text-xs text-link hover:underline"
          >
            {if @binding, do: "Bind here instead", else: "Bind"}
          </button>
        </li>
      </ul>

      <.confirm_dialog
        :for={{agent, key} <- other_candidates(@candidates, @binding)}
        :if={@can_manage?}
        id={"bind-target-#{agent.id}"}
        title={"Bind privileged jobs to #{agent.name}?"}
        confirm_label="Bind"
        variant="primary"
        on_confirm={
          JS.push("bind_target", value: %{agent_id: agent.id, fingerprint: key.fingerprint})
        }
      >
        <p>
          Bind only if this matches what <code class="font-mono">renga-agent fingerprint</code>
          prints on that host:
        </p>
        <p class="mt-2 break-all font-mono text-xs text-fg">{key.fingerprint}</p>
        <p :if={@binding} class="mt-2">
          Jobs waiting for {@binding.agent.name} will fail instead of moving.
        </p>
      </.confirm_dialog>

      <.confirm_dialog
        :if={@binding && @can_manage?}
        id="revoke-target-binding"
        title="Unbind privileged jobs?"
        confirm_label="Unbind"
        on_confirm={JS.push("revoke_target", value: %{id: @binding.id})}
      >
        Jobs waiting for {@binding.agent.name} will fail, and no privileged job can run on this
        resource until it is bound again.
      </.confirm_dialog>
    </section>
    """
  end

  defp other_candidates(candidates, nil), do: candidates

  defp other_candidates(candidates, binding) do
    Enum.reject(candidates, fn {agent, key} ->
      agent.id == binding.agent_id and key.id == binding.installation_key_id
    end)
  end

  defp short_fingerprint("SHA256:" <> digest), do: "SHA256:#{String.slice(digest, 0, 8)}…"
end
