defmodule RengaWeb.SecurityLive do
  @moduledoc """
  The organization's security settings (RFD 19, "Security settings"): each
  one with its current value and who last changed it. Everyone in the
  organization can see them; changing one needs `organization.manage`,
  and each change is recorded in Activity with a reason.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Accounts
  alias Renga.Authorization
  alias Renga.SecuritySettings
  alias RengaWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Security")
     |> assign(:has_factor?, Accounts.mfa?(socket.assigns.current_scope.user))
     |> load_settings()}
  end

  @impl true
  def handle_event("save", %{"setting" => %{"name" => name} = params}, socket) do
    %{current_scope: scope} = socket.assigns

    with {:ok, name} <- SecuritySettings.parse_name(name),
         {:ok, _value} <-
           SecuritySettings.put(scope, name, value(name, params), params["reason"]) do
      {:noreply, socket |> put_flash(:info, "Security setting saved.") |> after_change()}
    else
      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "Changing security settings needs organization.manage.")
         |> load_settings()}

      {:error, :reason_required} ->
        {:noreply,
         socket
         |> put_flash(:error, "Enter a reason for this security change.")
         |> load_settings()}

      _invalid ->
        {:noreply, put_flash(socket, :error, "That setting could not be saved.")}
    end
  end

  # The change may now ask this very session for a second factor before it
  # opens the organization (RFD 19), as on any other next request.
  defp after_change(socket) do
    previous = socket.assigns.current_scope
    scope = Accounts.scope_for_user(previous.user, previous.organization_id)

    case scope do
      %{organization_id: id} when id == previous.organization_id ->
        socket |> assign(:current_scope, scope) |> load_settings()

      %{mfa_organization: %{}} ->
        redirect(socket, to: ~p"/organizations/confirm-mfa")

      _no_longer_a_member ->
        redirect(socket, to: ~p"/organizations")
    end
  end

  defp value(:require_mfa, params), do: params["value"] == "true"

  defp load_settings(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      settings: SecuritySettings.list(scope),
      can_manage?: Authorization.allowed?(scope, "organization.manage")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:security}
    >
      <.settings_page
        id="security"
        title="Security"
        description="Protections this organization chooses to add. Renga always enforces the ones a feature needs to be safe; these go further, and each is off until an owner turns it on."
        class="max-w-3xl"
      >
        <.settings_section
          :for={setting <- @settings}
          id={"setting-#{setting.name}"}
          title={setting.label}
          description={setting.description}
        >
          <div class="space-y-3">
            <p class="flex flex-wrap items-center gap-2 text-sm text-fg">
              <span
                id={"setting-#{setting.name}-value"}
                class={[
                  "rounded px-1.5 py-0.5 text-xs font-medium",
                  if(setting.value,
                    do: "bg-accent-tint text-accent",
                    else: "bg-sunken text-fg-muted"
                  )
                ]}
              >
                {value_label(setting)}
              </span>
              <span id={"setting-#{setting.name}-changed"} class="text-xs text-fg-muted">
                {changed_label(setting)}
              </span>
            </p>

            <.form
              :if={@can_manage?}
              for={to_form(%{"name" => Atom.to_string(setting.name)}, as: "setting")}
              id={"setting-#{setting.name}-form"}
              phx-submit="save"
              class="space-y-3"
            >
              <input type="hidden" name="setting[name]" value={setting.name} />
              <.input
                type="checkbox"
                id={"setting-#{setting.name}-input"}
                name="setting[value]"
                value={setting.value}
                label={setting.label}
              />
              <p
                :if={setting.name == :require_mfa and not @has_factor?}
                id="setting-require_mfa-no-factor"
                class="text-xs text-warn-text"
              >
                Your account has no passkey or authenticator app yet. Once this is on, you'll
                need one to open this organization.
              </p>
              <.input
                type="text"
                id={"setting-#{setting.name}-reason"}
                name="setting[reason]"
                value=""
                label="Reason"
                placeholder="Recorded in Activity"
                maxlength="500"
                required
              />
              <.button variant="primary" size="sm" phx-disable-with="Saving…">Save</.button>
            </.form>

            <p :if={!@can_manage?} class="text-xs text-fg-muted">
              Only people who can change organization settings can change this.
            </p>
          </div>
        </.settings_section>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp value_label(%{type: :boolean, value: true}), do: "On"
  defp value_label(%{type: :boolean, value: false}), do: "Off"

  defp changed_label(%{changed_by: nil}), do: "Default, never changed"

  defp changed_label(%{changed_by: changed_by, changed_at: changed_at}),
    do: "Last changed by #{changed_by}, #{Format.datetime(changed_at)}"
end
