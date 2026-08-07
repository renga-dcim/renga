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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="organization-selector"
        class="mx-auto grid max-w-5xl gap-6 lg:grid-cols-[1.2fr_0.8fr]"
      >
        <div class="rounded-3xl border border-base-content/10 bg-base-100 p-6 shadow-sm sm:p-8">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600">Workspace</p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight">Choose an organization</h1>
          <p class="mt-2 max-w-xl text-sm leading-6 text-base-content/55">
            Inventory is isolated by organization. Select a workspace you belong to, or create one to get started.
          </p>

          <div id="organizations" phx-update="stream" class="mt-8 grid gap-3">
            <div
              :if={@memberships_empty?}
              id="organizations-empty"
              class="rounded-2xl border border-dashed border-base-content/15 p-8 text-center"
            >
              <.icon name="hero-building-office-2" class="mx-auto size-8 text-base-content/25" />
              <p class="mt-3 font-medium">No organizations yet</p>
              <p class="mt-1 text-xs text-base-content/45">
                Create your first workspace using the form.
              </p>
            </div>

            <article
              :for={{id, membership} <- @streams.memberships}
              id={id}
              class="flex flex-col gap-4 rounded-2xl border border-base-content/10 p-5 transition hover:border-orange-500/30 hover:bg-orange-500/[0.025] sm:flex-row sm:items-center"
            >
              <span class="grid size-11 shrink-0 place-items-center rounded-xl bg-orange-500/10 text-orange-600">
                <.icon name="hero-building-office-2" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <h2 class="truncate font-semibold">{membership.organization.name}</h2>
                <p class="mt-1 text-xs capitalize text-base-content/45">
                  {membership.role} · {membership.organization.slug}
                </p>
              </div>
              <.form
                for={@select_form}
                id={"select-organization-#{membership.organization_id}"}
                action={~p"/organizations/select"}
                method="post"
              >
                <input type="hidden" name="organization[id]" value={membership.organization_id} />
                <button class="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-base-content px-4 py-2.5 text-sm font-semibold text-base-100 transition hover:opacity-85 sm:w-auto">
                  Open inventory <.icon name="hero-arrow-right" class="size-4" />
                </button>
              </.form>
            </article>
          </div>
        </div>

        <aside class="rounded-3xl border border-base-content/10 bg-base-100 p-6 shadow-sm sm:p-8">
          <div class="flex items-center gap-3">
            <span class="grid size-10 place-items-center rounded-xl bg-emerald-500/10 text-emerald-600">
              <.icon name="hero-plus" class="size-5" />
            </span>
            <div>
              <h2 class="font-semibold">New organization</h2>
              <p class="text-xs text-base-content/45">You will become its owner.</p>
            </div>
          </div>

          <.form
            for={@organization_form}
            id="organization-form"
            phx-change="validate"
            phx-submit="create"
            class="mt-7 space-y-4"
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
            <button
              id="create-organization"
              class="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-orange-500 px-4 py-3 text-sm font-semibold text-white shadow-sm shadow-orange-500/20 transition hover:bg-orange-600 phx-submit-loading:opacity-60"
              phx-disable-with="Creating…"
            >
              Create organization
            </button>
          </.form>
        </aside>
      </section>
    </Layouts.app>
    """
  end

  defp organization_form do
    %Organization{}
    |> Accounts.change_organization()
    |> to_form()
  end
end
