defmodule RengaWeb.EnrollmentSettingsLive do
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Enrollment
  alias Renga.Enrollment.OIDCProfileSetup

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Enrollment")
     |> assign(:manager?, manager?(socket.assigns.current_scope))
     |> assign(:created_profile, nil)
     |> assign(:form, setup_form())
     |> load_profiles()}
  end

  @impl true
  def handle_event("validate", %{"profile" => params}, socket) do
    changeset = OIDCProfileSetup.changeset(%OIDCProfileSetup{}, params)
    {:noreply, assign(socket, :form, to_form(%{changeset | action: :validate}, as: :profile))}
  end

  def handle_event("create", %{"profile" => params}, socket) do
    case Enrollment.create_oidc_profile(socket.assigns.current_scope, params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:created_profile, profile)
         |> assign(:form, setup_form())
         |> put_flash(:info, "Enrollment profile created")
         |> load_profiles()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(%{changeset | action: :insert}, as: :profile))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage enrollment")}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    case Enrollment.disable_profile(socket.assigns.current_scope, id) do
      {:ok, _profile} ->
        {:noreply, socket |> put_flash(:info, "Enrollment profile disabled") |> load_profiles()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to manage enrollment")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not disable enrollment profile")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="enrollment-settings" class="space-y-8">
        <header>
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-orange-600">Trust plane</p>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight">OIDC enrollment</h1>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-base-content/55">
            Bind collector enrollment to a configured identity provider and an exact verified claim.
            Policies and verifier trust settings are immutable after creation.
          </p>
        </header>

        <section
          :if={@manager?}
          id="new-enrollment-panel"
          class="rounded-2xl border border-base-content/10 bg-base-100 p-6 shadow-sm"
        >
          <div class="mb-6">
            <h2 class="text-lg font-semibold">Create an enrollment profile</h2>
            <p class="mt-1 text-sm text-base-content/50">
              HTTPS is required. Enrollment fails closed unless the configured string claim exactly matches.
            </p>
          </div>
          <.form
            for={@form}
            id="enrollment-profile-form"
            phx-change="validate"
            phx-submit="create"
            class="grid gap-5 md:grid-cols-2 xl:grid-cols-3"
          >
            <.input field={@form[:name]} label="Display name" placeholder="Production collectors" />
            <.input field={@form[:selector]} label="Profile selector" placeholder="production" />
            <.input field={@form[:issuer]} label="Issuer URL" placeholder="https://id.example.com" />
            <.input field={@form[:audience]} label="Audience" placeholder="renga-agent" />
            <.input
              field={@form[:jwks_url]}
              label="JWKS URL"
              placeholder="https://id.example.com/.well-known/jwks.json"
            />
            <.input
              field={@form[:algorithm]}
              type="select"
              label="Signature algorithm"
              options={[{"RS256", "RS256"}, {"EdDSA", "EdDSA"}]}
            />
            <.input field={@form[:subject_claim]} label="Subject claim path" placeholder="sub" />
            <.input
              field={@form[:subject_cardinality]}
              type="select"
              label="Subject cardinality"
              options={[{"Singleton", "singleton"}, {"Group", "group"}]}
            />
            <.input
              field={@form[:binding_mode]}
              type="select"
              label="Binding mode"
              options={[
                {"Challenge bound (recommended)", "challenge_bound"},
                {"Bearer unbound", "bearer_unbound"}
              ]}
            />
            <.input
              field={@form[:authorized_party]}
              label="Authorized party (optional)"
              placeholder="client-id"
            />
            <.input
              field={@form[:required_claim_path]}
              label="Required claim path"
              placeholder="role"
            />
            <.input
              field={@form[:required_claim_value]}
              label="Required claim value"
              placeholder="installer"
            />
            <.input
              :if={@form[:subject_cardinality].value == "group"}
              field={@form[:group_max]}
              type="number"
              min="1"
              max="10000"
              label="Maximum active group bindings"
            />
            <div class="flex items-end md:col-span-2 xl:col-span-3">
              <button
                id="create-enrollment-profile"
                type="submit"
                class="inline-flex items-center gap-2 rounded-xl bg-orange-500 px-5 py-2.5 text-sm font-semibold text-white shadow-sm shadow-orange-500/20 transition hover:-translate-y-0.5 hover:bg-orange-600"
              >
                <.icon name="hero-shield-check" class="size-4" /> Create immutable configuration
              </button>
            </div>
          </.form>
        </section>

        <section
          :if={@created_profile}
          id="agent-config-snippet"
          class="rounded-2xl border border-emerald-500/20 bg-base-100 p-6 shadow-sm"
        >
          <h2 class="font-semibold">Profile ready to deploy</h2>
          <p class="mt-1 text-sm text-base-content/50">
            Save this as <code>agent.toml</code>. Place the OIDC token at the listed path; no secret is included here.
          </p>
          <code class="mt-4 block whitespace-pre-wrap rounded-xl bg-slate-950 p-4 font-mono text-xs leading-6 text-slate-100">
            {agent_config(@current_scope, @created_profile)}
          </code>
        </section>

        <section aria-labelledby="profiles-heading" class="space-y-4">
          <div class="flex items-center justify-between">
            <h2 id="profiles-heading" class="text-lg font-semibold">Enrollment profiles</h2>
            <span id="profile-count" class="text-sm text-base-content/45">
              {length(@profiles)} configured
            </span>
          </div>
          <div id="enrollment-profiles" class="grid gap-4 xl:grid-cols-2">
            <div
              :if={@profiles == []}
              id="empty-enrollment-profiles"
              class="rounded-2xl border border-dashed border-base-content/15 bg-base-100 p-8 text-center text-sm text-base-content/50"
            >
              No OIDC enrollment profiles configured.
            </div>
            <article
              :for={profile <- @profiles}
              id={"enrollment-profile-#{profile.id}"}
              class="rounded-2xl border border-base-content/10 bg-base-100 p-5 shadow-sm"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <h3 class="font-semibold">{profile.name}</h3>
                  <p class="mt-1 font-mono text-xs text-base-content/50">{profile.selector}</p>
                </div>
                <span class={[
                  "rounded-full px-2.5 py-1 text-xs font-semibold",
                  if(profile.enabled,
                    do: "bg-emerald-500/10 text-emerald-700",
                    else: "bg-base-200 text-base-content/45"
                  )
                ]}>
                  {if(profile.enabled, do: "Enabled", else: "Disabled")}
                </span>
              </div>
              <dl class="mt-5 grid grid-cols-2 gap-4 text-sm">
                <div>
                  <dt class="text-xs text-base-content/45">Policy</dt>
                  <dd class="mt-1">
                    {policy(@policies, profile).name} · v{policy(@policies, profile).version}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs text-base-content/45">Verifier</dt>
                  <dd class="mt-1">
                    {verifier(@verifiers, profile).name} · v{verifier(@verifiers, profile).version}
                  </dd>
                </div>
                <div class="col-span-2">
                  <dt class="text-xs text-base-content/45">Issuer / audience</dt>
                  <dd class="mt-1 break-all">
                    {verifier(@verifiers, profile).configuration["issuer"]} · {Enum.join(
                      verifier(@verifiers, profile).configuration["audiences"],
                      ", "
                    )}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs text-base-content/45">Cardinality</dt>
                  <dd class="mt-1">{verifier(@verifiers, profile).subject_cardinality}</dd>
                </div>
                <div>
                  <dt class="text-xs text-base-content/45">Binding</dt>
                  <dd class="mt-1">{verifier(@verifiers, profile).configuration["binding_mode"]}</dd>
                </div>
              </dl>
              <button
                :if={@manager? && profile.enabled}
                id={"disable-enrollment-profile-#{profile.id}"}
                type="button"
                phx-click="disable"
                phx-value-id={profile.id}
                data-confirm="Disable this enrollment profile immediately?"
                class="mt-5 rounded-lg border border-red-500/20 px-3 py-2 text-xs font-semibold text-red-600 transition hover:bg-red-500/5"
              >
                Disable profile
              </button>
            </article>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp setup_form,
    do: %OIDCProfileSetup{} |> OIDCProfileSetup.changeset(%{}) |> to_form(as: :profile)

  defp load_profiles(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      profiles: Enrollment.list_profiles(scope),
      policies: by_id(Enrollment.list_policies(scope)),
      verifiers: by_id(Enrollment.list_verifier_configurations(scope))
    )
  end

  defp by_id(rows), do: Map.new(rows, &{&1.id, &1})
  defp policy(rows, profile), do: Map.fetch!(rows, profile.enrollment_policy_id)
  defp verifier(rows, profile), do: Map.fetch!(rows, profile.verifier_configuration_id)
  defp manager?(scope), do: Enum.any?(scope.roles, &(&1 in ["owner", "admin"]))

  defp agent_config(scope, profile) do
    "renga_url = \"#{RengaWeb.Endpoint.url()}\"\nauth_mode = \"enrolled\"\norganization = \"#{scope.organization.slug}\"\nprofile = \"#{profile.selector}\"\noidc_token_file = \"/run/secrets/renga-oidc-token\"\nstate_path = \"/var/lib/renga-agent\""
  end
end
