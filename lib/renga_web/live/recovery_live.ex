defmodule RengaWeb.RecoveryLive do
  @moduledoc "The page every browser route shows while Renga is in recovery mode (RFD 15)."

  use RengaWeb, :live_view

  alias Renga.Accounts.SignInPolicy

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.auth_card id="recovery" title="Renga is in recovery mode">
        <:subtitle>
          Nobody can sign in right now: local sign-in is turned off and no identity provider is active.
        </:subtitle>

        <div class="space-y-3 text-sm text-fg">
          <p>An operator can restore access with a release command on the server:</p>
          <ul class="space-y-3">
            <li id="recovery-test-provider" class="space-y-1">
              <.command parts={["bin/providers test ID", "--actor NAME"]} />
              <p class="text-fg-muted">Prints a link that tests a provider and activates it.</p>
            </li>
            <li id="recovery-recover-local" class="space-y-1">
              <.command parts={["bin/providers recover-local", "--actor NAME", "--minutes 60"]} />
              <p class="text-fg-muted">Turns local sign-in on for a while.</p>
            </li>
          </ul>
        </div>
      </.auth_card>
    </Layouts.app>
    """
  end

  # A command in its own block, above its description. It wraps only
  # between `parts`, so a flag never breaks from its value or at its hyphen,
  # and the text copies as the one-line command.
  attr :parts, :list, required: true

  defp command(assigns) do
    ~H"""
    <code
      class="block rounded-md bg-sunken px-3 py-2 font-mono text-xs leading-6 text-fg"
      phx-no-format
    ><%= for {part, index} <- Enum.with_index(@parts) do %>{if index > 0, do: " "}<span class="whitespace-nowrap">{part}</span><% end %></code>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if SignInPolicy.recovery_mode?(),
      do: {:ok, socket},
      else: {:ok, push_navigate(socket, to: ~p"/users/log-in")}
  end
end
