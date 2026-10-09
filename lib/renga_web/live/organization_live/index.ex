defmodule RengaWeb.OrganizationLive.Index do
  use RengaWeb, :live_view

  alias Renga.Accounts
  alias Renga.Accounts.Organization

  @impl true
  def mount(_params, _session, socket) do
    memberships = Accounts.list_user_organization_memberships(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:page_title, "Choose organization")
     |> assign(:memberships_empty?, memberships == [])
     |> assign(:organization_form, organization_form())
     |> assign(:select_form, to_form(%{}, as: :organization))
     |> stream_configure(:memberships, dom_id: &"organization-#{&1.organization_id}")
     |> stream(:memberships, memberships)}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    form =
      %Organization{}
      |> Accounts.change_organization(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :organization_form, form)}
  end

  def handle_event("create", %{"organization" => params}, socket) do
    case Accounts.create_organization_for_user(socket.assigns.current_scope.user, params) do
      {:ok, {organization, membership}} ->
        membership = %{membership | organization: organization}

        {:noreply,
         socket
         |> assign(:memberships_empty?, false)
         |> assign(:organization_form, organization_form())
         |> stream_insert(:memberships, membership)
         |> put_flash(:info, "Organization created. Select it to open inventory.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :organization_form, to_form(changeset, action: :insert))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:organizations}
    >
      <.settings_page
        id="organization-selector"
        title="Organizations"
        description="Inventory is kept separate per organization. Open one you belong to, or create one to get started."
        class="max-w-3xl"
      >
        <.settings_section
          id="your-organizations"
          title="Your organizations"
          description="Opening one makes it the organization you work in."
        >
          <ul
            id="organizations"
            phx-update="stream"
            class="divide-y divide-line rounded-lg border border-edge bg-surface"
          >
            <li
              :if={@memberships_empty?}
              id="organizations-empty"
              class="px-4 py-8 text-center text-sm text-fg-muted"
            >
              No organizations yet. Create the first one below.
            </li>
            <li
              :for={{id, membership} <- @streams.memberships}
              id={id}
              class="flex flex-wrap items-center gap-3 px-3 py-2.5"
            >
              <span class="grid size-8 shrink-0 place-items-center rounded-md border border-edge bg-sunken text-fg-muted">
                <.icon name="hero-building-office-2" class="size-4" />
              </span>
              <div class="min-w-0 flex-1">
                <p class="flex items-center gap-2 truncate text-sm font-medium text-fg">
                  {membership.organization.name}
                  <span
                    :if={@current_scope.organization_id == membership.organization_id}
                    class="rounded bg-accent-tint px-1.5 py-0.5 text-[11px] font-medium text-accent"
                  >
                    Current
                  </span>
                </p>
                <p class="truncate text-xs text-fg-muted">
                  <span class="capitalize">{membership.role}</span>
                  · <span class="font-mono">{membership.organization.slug}</span>
                </p>
              </div>
              <.form
                for={@select_form}
                id={"select-organization-#{membership.organization_id}"}
                action={~p"/organizations/select"}
                method="post"
              >
                <input type="hidden" name="organization[id]" value={membership.organization_id} />
                <.button size="sm">
                  Open <.icon name="hero-arrow-right-mini" class="size-4" />
                </.button>
              </.form>
            </li>
          </ul>
        </.settings_section>

        <.settings_section
          id="new-organization"
          title="New organization"
          description="You become its owner and can invite others."
        >
          <.form
            for={@organization_form}
            id="organization-form"
            phx-change="validate"
            phx-submit="create"
          >
            <.input
              field={@organization_form[:name]}
              type="text"
              label="Organization name"
              placeholder="Acme Operations"
              required
            />
            <.input
              field={@organization_form[:slug]}
              type="text"
              label="URL-safe slug"
              placeholder="acme-operations"
              pattern="[a-z0-9][a-z0-9-]*"
              required
            />
            <.button id="create-organization" variant="primary" phx-disable-with="Creating…">
              Create organization
            </.button>
          </.form>
        </.settings_section>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp organization_form do
    %Organization{}
    |> Accounts.change_organization()
    |> to_form()
  end
end
