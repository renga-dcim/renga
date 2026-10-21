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
          <ul class="list-disc space-y-1 pl-5">
            <li>
              <code class="font-mono">renga providers test ID</code>
              prints a link that tests a provider and activates it.
            </li>
            <li>
              <code class="font-mono">renga providers recover-local --minutes 60</code>
              turns local sign-in on for a while.
            </li>
          </ul>
        </div>
      </.auth_card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if SignInPolicy.recovery_mode?(),
      do: {:ok, socket},
      else: {:ok, push_navigate(socket, to: ~p"/users/log-in")}
  end
end
