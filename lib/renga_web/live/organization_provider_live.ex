defmodule RengaWeb.OrganizationProviderLive do
  @moduledoc """
  Settings → Identity providers: the organization's own OpenID Connect
  providers, such as its Okta or Microsoft Entra ID tenant (RFD 15,
  "Organization providers"). Owners add one with the callback URL it shows,
  and new settings stay pending until the owner's own test sign-in against
  them works, which activates them. Everyone else is told who manages them.
  `Renga.Accounts.OrganizationProviders` re-checks every change.
  """
  use RengaWeb, :live_view

  on_mount {RengaWeb.UserAuth, :require_organization}

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationDomains
  alias Renga.Accounts.OrganizationProviders

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: "Identity providers", manage?: OrganizationProviders.manage?(scope))
     |> assign(editing: nil, new_id: nil, form: to_form(%{}, as: "provider"))
     |> assign(:domain_form, to_form(%{}, as: "domain"))
     |> load()}
  end

  @impl true
  def handle_event("add_domain", %{"domain" => %{"domain" => domain}}, socket) do
    case OrganizationDomains.add(socket.assigns.current_scope, domain) do
      {:ok, claim} ->
        {:noreply,
         socket
         |> put_flash(:info, "Publish the TXT record for #{claim.domain}, then check it.")
         |> assign(:domain_form, to_form(%{}, as: "domain"))
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :domain_form, to_form(changeset, as: "domain", action: :insert))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event(action, %{"id" => id}, socket)
      when action in ~w(verify_domain remove_domain) do
    with %{} = claim <- Enum.find(socket.assigns.domains, &(&1.id == id)),
         {:ok, claim} <- domain_action(action, socket.assigns.current_scope, claim) do
      {:noreply, socket |> put_flash(:info, domain_done(action, claim)) |> load()}
    else
      error -> {:noreply, socket |> put_flash(:error, domain_refusal(error)) |> load()}
    end
  end

  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(editing: nil, new_id: OrganizationProviders.new_id())
     |> assign(:form, to_form(%{"allow_sign_up" => "false"}, as: "provider"))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, load(socket)}

      %{provider: provider, revision: revision} ->
        {:noreply,
         socket
         |> assign(editing: provider, new_id: nil)
         |> assign(:form, to_form(form_values(provider, revision), as: "provider"))}
    end
  end

  def handle_event("save", %{"provider" => params}, %{assigns: %{editing: nil}} = socket) do
    attrs =
      params
      |> revision_attrs()
      |> Map.merge(%{
        "id" => socket.assigns.new_id,
        "display_name" => params["display_name"],
        "issuer" => params["issuer"]
      })

    case OrganizationProviders.create(socket.assigns.current_scope, attrs) do
      {:ok, {provider, _revision}} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{provider.display_name} added. Test its sign-in to turn it on.")
         |> close_overlay("provider-panel")
         |> assign(new_id: nil)
         |> load()}

      error ->
        {:noreply, failed(socket, error, params)}
    end
  end

  def handle_event("save", %{"provider" => params}, %{assigns: %{editing: provider}} = socket) do
    scope = socket.assigns.current_scope

    with {:ok, provider} <-
           OrganizationProviders.update_display(scope, provider, %{
             "display_name" => params["display_name"]
           }),
         {:ok, _} <- propose(scope, provider, revision_attrs(params)) do
      {:noreply,
       socket
       |> put_flash(:info, "#{provider.display_name} saved.")
       |> close_overlay("provider-panel")
       |> assign(editing: nil)
       |> load()}
    else
      error -> {:noreply, failed(socket, error, params)}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    with %{provider: provider} <- find(socket, id),
         {:ok, {token, _test}} <-
           OrganizationProviders.create_test(socket.assigns.current_scope, provider) do
      {:noreply, redirect(socket, to: ~p"/users/providers/test/#{token}")}
    else
      error -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event(action, %{"id" => id}, socket)
      when action in ~w(discard enable disable remove) do
    fun =
      case action do
        "discard" -> &OrganizationProviders.discard_pending/2
        "enable" -> &OrganizationProviders.enable/2
        "disable" -> &OrganizationProviders.disable/2
        "remove" -> &OrganizationProviders.remove/2
      end

    with %{provider: provider} <- find(socket, id),
         {:ok, _provider} <- fun.(socket.assigns.current_scope, provider) do
      {:noreply, socket |> put_flash(:info, done(action, provider)) |> load()}
    else
      error -> {:noreply, refused(socket, error)}
    end
  end

  # Saving only the name proposes no new settings.
  defp propose(scope, provider, attrs) do
    case OrganizationProviders.propose_revision(scope, provider, attrs) do
      {:error, :no_changes} -> {:ok, provider}
      result -> result
    end
  end

  defp failed(socket, {:error, %Ecto.Changeset{} = changeset}, params) do
    errors =
      for {field, {message, opts}} <- changeset.errors,
          do: {field, {message, opts}}

    # The submitted secret is never sent back to the browser.
    params = Map.delete(params, "client_secret")
    assign(socket, :form, to_form(params, as: "provider", errors: errors, action: :insert))
  end

  defp failed(socket, error, _params), do: refused(socket, error)

  defp refused(socket, {:error, :forbidden}),
    do:
      socket
      |> put_flash(:error, "Only organization owners can change identity providers.")
      |> load()

  defp refused(socket, {:error, :no_encryption_key}),
    do: put_flash(socket, :error, "This server can't store client secrets yet. Ask its operator.")

  defp refused(socket, {:error, :nothing_pending}),
    do: socket |> put_flash(:error, "There are no new settings to test.") |> load()

  defp refused(socket, {:error, :no_active_revision}),
    do:
      put_flash(
        socket,
        :error,
        "A new provider has only these settings. Edit or remove it instead."
      )

  defp refused(socket, _error),
    do: socket |> put_flash(:error, "That provider changed. Try again.") |> load()

  defp domain_action("verify_domain", scope, claim), do: OrganizationDomains.verify(scope, claim)
  defp domain_action("remove_domain", scope, claim), do: OrganizationDomains.remove(scope, claim)

  defp domain_done("verify_domain", claim),
    do: "#{claim.domain} is verified. People with that email domain can now find your sign-in."

  defp domain_done("remove_domain", claim), do: "#{claim.domain} removed."

  defp domain_refusal({:error, :record_not_found}),
    do: "Renga couldn't find the TXT record yet. DNS changes can take a while to appear."

  defp domain_refusal({:error, :dns_unavailable}),
    do: "DNS didn't answer. Try checking again in a minute."

  defp domain_refusal({:error, :verified_elsewhere}),
    do: "Another organization has verified that domain and still has its record."

  defp domain_refusal({:error, :forbidden}),
    do: "Only organization owners can change email domains."

  defp domain_refusal(_error), do: "That domain changed. Try again."

  defp done("discard", provider), do: "Discarded the new settings for #{provider.display_name}."
  defp done("enable", provider), do: "Sign-in with #{provider.display_name} is on."
  defp done("disable", provider), do: "Sign-in with #{provider.display_name} is off."
  defp done("remove", provider), do: "#{provider.display_name} removed."

  defp revision_attrs(params) do
    %{
      "client_id" => params["client_id"],
      "client_secret" => params["client_secret"],
      "scopes" => split(params["scopes"]),
      "email_domains" => split(params["email_domains"]),
      "allow_sign_up" => params["allow_sign_up"] == "true"
    }
  end

  defp split(nil), do: []
  defp split(value), do: value |> String.split([",", " ", "\n"], trim: true)

  defp form_values(provider, %Revision{} = revision) do
    %{
      "display_name" => provider.display_name,
      "issuer" => provider.issuer,
      "client_id" => revision.client_id,
      "scopes" => Enum.join(revision.scopes, ", "),
      "email_domains" => Enum.join(revision.email_domains, ", "),
      "allow_sign_up" => to_string(revision.allow_sign_up)
    }
  end

  defp find(socket, id), do: Enum.find(socket.assigns.providers, &(&1.provider.id == id))

  defp load(socket) do
    providers =
      if socket.assigns.manage? do
        for provider <- OrganizationProviders.list(socket.assigns.current_scope) do
          active = IdentityProviders.active_revision(provider)
          pending = IdentityProviders.pending_revision(provider)
          %{provider: provider, active: active, pending: pending, revision: pending || active}
        end
      else
        []
      end

    domains =
      if socket.assigns.manage?,
        do: OrganizationDomains.list(socket.assigns.current_scope),
        else: []

    assign(socket, providers: providers, domains: domains)
  end

  defp callback_url(id), do: url(~p"/users/auth/#{id}/callback")

  defp status(%{provider: %IdentityProvider{active_revision: nil}}),
    do: "Waiting for a test sign-in"

  defp status(%{provider: %IdentityProvider{enabled: false}}), do: "Off"
  defp status(%{pending: %Revision{}}), do: "On · new settings waiting for a test sign-in"
  defp status(_entry), do: "On"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      sidebar_views={@sidebar_views}
      current_scope={@current_scope}
      active_nav={:identity_providers}
    >
      <.settings_page
        id="identity-providers"
        title="Identity providers"
        description="Let members sign in with your organization's own OpenID Connect provider, such as Okta or Microsoft Entra ID. It signs people in to this organization only."
        class="max-w-4xl"
      >
        <:actions>
          <.button
            :if={@manage?}
            id="new-provider"
            variant="primary"
            phx-click={JS.push("new") |> show_overlay("provider-panel")}
          >
            Add provider
          </.button>
        </:actions>

        <p :if={!@manage?} id="providers-owners-only" class="text-sm text-fg-muted">
          Only organization owners can see and change identity providers.
        </p>

        <.table
          :if={@manage?}
          id="provider-list"
          rows={@providers}
          row_id={&"provider-#{&1.provider.id}"}
          class="rounded-lg border border-edge bg-surface"
        >
          <:col :let={entry} label="Provider" class="py-2">
            <span class="block font-medium text-fg">{entry.provider.display_name}</span>
            <span class="block truncate font-mono text-xs text-fg-muted">
              {entry.provider.issuer}
            </span>
          </:col>
          <:col :let={entry} label="Status">
            <span id={"provider-#{entry.provider.id}-status"} class="text-sm text-fg-muted">
              {status(entry)}
            </span>
          </:col>
          <:col :let={entry} label="Callback URL">
            <span class="block break-all font-mono text-xs text-fg-muted">
              {callback_url(entry.provider.id)}
            </span>
          </:col>
          <:action :let={entry}>
            <button
              :if={entry.pending}
              id={"provider-#{entry.provider.id}-test"}
              type="button"
              phx-click="test"
              phx-value-id={entry.provider.id}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Test sign-in
            </button>
            <button
              id={"provider-#{entry.provider.id}-edit"}
              type="button"
              phx-click={
                JS.push("edit", value: %{id: entry.provider.id}) |> show_overlay("provider-panel")
              }
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Edit
            </button>
            <button
              :if={entry.pending && entry.active}
              id={"provider-#{entry.provider.id}-discard"}
              type="button"
              phx-click="discard"
              phx-value-id={entry.provider.id}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              Discard new settings
            </button>
            <button
              :if={entry.active}
              id={"provider-#{entry.provider.id}-toggle"}
              type="button"
              phx-click={if entry.provider.enabled, do: "disable", else: "enable"}
              phx-value-id={entry.provider.id}
              class="min-h-tap cursor-pointer text-sm text-link hover:underline"
            >
              {if entry.provider.enabled, do: "Turn off", else: "Turn on"}
            </button>
            <button
              id={"provider-#{entry.provider.id}-remove"}
              type="button"
              phx-click={show_overlay("remove-provider-#{entry.provider.id}")}
              class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
            >
              Remove
            </button>
          </:action>
          <:empty>
            No identity providers yet. Add your organization's OpenID Connect provider to let
            members sign in with it.
          </:empty>
        </.table>

        <.settings_section
          :if={@manage?}
          id="organization-domains"
          title="Email domains"
          description="Prove you own your email domain with a DNS TXT record, and people who enter an address at that domain on the sign-in page are sent to your identity provider. Only one organization can verify a domain."
        >
          <ul id="domain-list" class="divide-y divide-line rounded-lg border border-edge bg-surface">
            <li :if={@domains == []} class="px-4 py-6 text-center text-sm text-fg-muted">
              No email domains yet.
            </li>
            <li :for={claim <- @domains} id={"domain-#{claim.id}"} class="space-y-2 px-3 py-2.5">
              <div class="flex flex-wrap items-center gap-3">
                <span class="min-w-0 flex-1 truncate font-mono text-sm text-fg">{claim.domain}</span>
                <span id={"domain-#{claim.id}-status"} class="text-sm text-fg-muted">
                  {if claim.verified_at, do: "Verified", else: "Waiting for its DNS record"}
                </span>
                <button
                  :if={!claim.verified_at}
                  id={"domain-#{claim.id}-verify"}
                  type="button"
                  phx-click="verify_domain"
                  phx-value-id={claim.id}
                  class="min-h-tap cursor-pointer text-sm text-link hover:underline"
                >
                  Check now
                </button>
                <button
                  id={"domain-#{claim.id}-remove"}
                  type="button"
                  phx-click="remove_domain"
                  phx-value-id={claim.id}
                  data-confirm={"Remove #{claim.domain}?"}
                  class="min-h-tap cursor-pointer text-sm text-crit hover:underline"
                >
                  Remove
                </button>
              </div>
              <dl
                :if={!claim.verified_at}
                id={"domain-#{claim.id}-record"}
                class="grid gap-1 rounded-md bg-sunken p-3 text-xs sm:grid-cols-[auto_1fr] sm:gap-x-3"
              >
                <dt class="text-fg-muted">TXT name</dt>
                <dd class="break-all font-mono text-fg">{OrganizationDomains.record_name(claim)}</dd>
                <dt class="text-fg-muted">Value</dt>
                <dd class="break-all font-mono text-fg">{OrganizationDomains.record_value(claim)}</dd>
              </dl>
            </li>
          </ul>
          <.form
            for={@domain_form}
            id="domain-form"
            phx-submit="add_domain"
            class="mt-3 flex flex-wrap items-end gap-2"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@domain_form[:domain]}
                type="text"
                label="Domain"
                placeholder="example.com"
                autocomplete="off"
                spellcheck="false"
                required
              />
            </div>
            <.button id="add-domain" phx-disable-with="Adding…">Add domain</.button>
          </.form>
        </.settings_section>
      </.settings_page>

      <.confirm_dialog
        :for={entry <- @providers}
        id={"remove-provider-#{entry.provider.id}"}
        title={"Remove #{entry.provider.display_name}?"}
        confirm_label="Remove provider"
        on_confirm={JS.push("remove", value: %{id: entry.provider.id})}
      >
        Nobody can sign in with it afterwards, and its saved client secret is deleted.
      </.confirm_dialog>

      <.side_panel
        :if={@manage?}
        id="provider-panel"
        title={if @editing, do: "Edit #{@editing.display_name}", else: "Add a provider"}
        description={
          if @editing,
            do:
              "Changes to the client or sign-in rules wait for a test sign-in before they take effect.",
            else:
              "Register Renga at your identity provider with this callback URL, then enter the client it gives you."
        }
      >
        <div :if={@new_id} id="provider-callback" class="mb-4 rounded-md bg-sunken p-3">
          <p class="text-xs text-fg-muted">Callback URL</p>
          <p class="break-all font-mono text-sm text-fg">{callback_url(@new_id)}</p>
        </div>
        <.form for={@form} id="provider-form" phx-submit="save">
          <.input field={@form[:display_name]} type="text" label="Name" required autocomplete="off" />
          <.input
            :if={!@editing}
            field={@form[:issuer]}
            type="url"
            label="Issuer URL"
            placeholder="https://login.example.com"
            required
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:client_id]}
            type="text"
            label="Client ID"
            required
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:client_secret]}
            value=""
            type="password"
            label={
              if @editing,
                do: "Client secret (leave empty to keep the saved one)",
                else: "Client secret"
            }
            required={!@editing}
            autocomplete="new-password"
          />
          <.input
            field={@form[:email_domains]}
            type="text"
            label="Allowed email domains (optional, comma-separated)"
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:scopes]}
            type="text"
            label="Extra scopes (optional)"
            autocomplete="off"
            spellcheck="false"
          />
          <.input
            field={@form[:allow_sign_up]}
            type="checkbox"
            label="Create a Renga account for someone signing in for the first time"
          />
          <div class="mt-4 flex justify-end gap-2">
            <.button type="button" phx-click={hide_overlay("provider-panel")}>Cancel</.button>
            <.button id="provider-save" variant="primary" phx-disable-with="Saving…">
              Save
            </.button>
          </div>
        </.form>
      </.side_panel>
    </Layouts.app>
    """
  end
end
