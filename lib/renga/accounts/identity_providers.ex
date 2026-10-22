defmodule Renga.Accounts.IdentityProviders do
  @moduledoc """
  Identity providers stored in the database (RFD 15, "Storage and
  changes"). Release commands and the operator API (RFD 22) both manage
  deployment providers through this module, and
  `Renga.Accounts.OrganizationProviders` manages an organization's providers
  through it after checking the owner may, so there is one store and one set
  of rules.

  A provider's authentication settings change only through revisions: an edit
  writes a pending revision while the active one stays in use, and only a
  tested pending revision becomes active. Display fields change in place.
  Every change increments the provider's `version`, which nodes compare before
  using a cached copy, and is recorded as an `IdentityProviderEvent` with its
  actor and the fields it changed, never a secret.

  Changes are serialized under one lock with a guard that refuses to leave the
  deployment without a way to sign in.

  An actor is `{:user, %User{}}` or `{:operator, name}`, where `name` says who
  ran a release command or which operator token called the API.

  Each change locks the provider it was given within that provider's scope,
  so a function called with a deployment provider never changes an
  organization's, and the other way round. An organization provider's
  changes are also recorded in the organization's Activity; they never count
  toward the deployment's last way to sign in.
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderEvent
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviderTest
  alias Renga.Accounts.SignInPolicy
  alias Renga.Accounts.User
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo
  alias Renga.Vault

  @test_minutes 15

  @doc "The deployment's providers that have not been removed, by display name."
  def list do
    deployment()
    |> order_by([provider], asc: provider.display_name, asc: provider.id)
    |> Repo.all()
  end

  @doc """
  The providers the sign-in page offers: every usable one not hidden, plus
  the hidden provider `revealed` names (`/users/log-in?provider=<id>`).
  """
  def sign_in_options(revealed \\ nil) do
    usable_deployment()
    |> where([provider], not provider.hidden or provider.id == ^(revealed || ""))
    |> order_by([provider], asc: provider.display_name, asc: provider.id)
    |> Repo.all()
  end

  @doc "A deployment provider by ID, or nil when there is none or it was removed."
  def get(id) when is_binary(id), do: Repo.get(deployment(), id)

  @doc """
  A provider of either scope by ID, or nil. Only for paths that act on a
  provider already chosen through a scoped lookup, such as a test sign-in
  whose test an operator or owner created, or that bind the result to the
  provider's scope, such as sign-in.
  """
  def get_any(id) when is_binary(id),
    do: Repo.one(from p in IdentityProvider, where: p.id == ^id and is_nil(p.removed_at))

  @doc """
  The active organization with `slug` and the providers its members can
  sign in with now, for its sign-in link (`/users/log-in?organization=`),
  or nil when it has none.
  """
  def organization_sign_in_options(slug) when is_binary(slug) do
    providers =
      IdentityProvider
      |> join(:inner, [provider], organization in assoc(provider, :organization))
      |> where([provider, organization], organization.slug == ^slug)
      |> where([provider, organization], organization.status == "active")
      |> where([provider], is_nil(provider.removed_at))
      |> where([provider], provider.enabled and not is_nil(provider.active_revision))
      |> order_by([provider], asc: provider.display_name, asc: provider.id)
      |> preload([provider, organization], organization: organization)
      |> Repo.all()

    case providers do
      [] -> nil
      [first | _] -> {first.organization, providers}
    end
  end

  def organization_sign_in_options(_slug), do: nil

  @doc "An organization's providers that have not been removed, by display name."
  def list_for_organization(organization_id) when is_binary(organization_id) do
    organization_id
    |> organization()
    |> order_by([provider], asc: provider.display_name, asc: provider.id)
    |> Repo.all()
  end

  @doc "One of an organization's providers by ID, or nil."
  def get_for_organization(organization_id, id) when is_binary(organization_id) and is_binary(id),
    do: Repo.get(organization(organization_id), id)

  @doc "A provider's revision by number."
  def revision(%IdentityProvider{id: id}, number) when is_integer(number),
    do: Repo.get_by(Revision, provider_id: id, number: number)

  def revision(%IdentityProvider{}, nil), do: nil

  @doc "The revision sign-in uses, or nil before the first activation."
  def active_revision(%IdentityProvider{} = provider),
    do: revision(provider, provider.active_revision)

  @doc "The revision waiting for a test sign-in, or nil."
  def pending_revision(%IdentityProvider{} = provider),
    do: revision(provider, provider.pending_revision)

  @doc "Whether people can sign in with the provider now."
  def usable?(%IdentityProvider{} = provider) do
    provider.enabled and is_nil(provider.removed_at) and not is_nil(provider.active_revision)
  end

  @doc """
  Whether the deployment has a way to sign in: local credentials, or an
  enabled deployment provider with an active revision.
  """
  def sign_in_available? do
    SignInPolicy.local_sign_in?() or Repo.exists?(usable_deployment())
  end

  @doc """
  Adds a deployment provider, or with `organization_id:` an organization's.
  Its settings become revision 1, pending until a test sign-in activates
  it, so a new provider takes no sign-ins yet.
  """
  def create(attrs, actor, opts \\ []) do
    provider_changeset =
      IdentityProvider.create_changeset(%IdentityProvider{}, attrs, opts[:organization_id])

    kind = Ecto.Changeset.get_field(provider_changeset, :kind)
    revision_changeset = Revision.changeset(%Revision{}, attrs, kind)

    if provider_changeset.valid? and revision_changeset.valid? do
      serialized(fn -> insert_provider(provider_changeset, revision_changeset, actor) end)
    else
      {:error, merge_errors(provider_changeset, revision_changeset)}
    end
  end

  defp insert_provider(provider_changeset, revision_changeset, actor) do
    with {:ok, provider} <-
           provider_changeset
           |> Ecto.Changeset.put_change(:pending_revision, 1)
           |> Repo.insert(),
         {:ok, revision} <- insert_revision(revision_changeset, provider, 1, actor) do
      changed = changed_fields(provider_changeset) ++ changed_fields(revision_changeset)
      record(provider, "created", actor, revision: 1, changed: changed)
      {:ok, {provider, revision}}
    end
  end

  @doc "Changes the display name, icon, or whether the sign-in page hides the provider."
  def update_display(%IdentityProvider{} = provider, attrs, actor) do
    change_provider(provider, fn provider ->
      changeset = IdentityProvider.display_changeset(provider, attrs)

      case changed_fields(changeset) do
        [] -> {:ok, provider}
        changed -> save(changeset, "updated", actor, changed: changed)
      end
    end)
  end

  @doc """
  Writes a new pending revision from the pending one, or the active one when
  nothing is pending, with `attrs` applied. It replaces any earlier pending
  revision, so a test of that one no longer counts. An empty client secret
  keeps the saved one. Returns `{:error, :no_changes}` when `attrs` change
  nothing.
  """
  def propose_revision(%IdentityProvider{} = provider, attrs, actor) do
    change_provider(provider, &propose(&1, attrs, actor))
  end

  defp propose(provider, attrs, actor) do
    base = pending_revision(provider) || active_revision(provider)
    changeset = Revision.changeset(base, attrs, provider.kind)
    number = next_revision_number(provider)

    with [_ | _] = changed <- changed_fields(changeset),
         {:ok, revision} <- insert_revision(changeset, provider, number, actor),
         {:ok, provider} <-
           provider
           |> Ecto.Changeset.change(pending_revision: number)
           |> save("revision_pending", actor, revision: number, changed: changed) do
      {:ok, {provider, revision}}
    else
      [] -> {:error, :no_changes}
      error -> error
    end
  end

  @doc "Discards the pending revision, leaving the active one in use."
  def discard_pending(%IdentityProvider{} = provider, actor) do
    change_provider(provider, fn
      %IdentityProvider{pending_revision: nil} ->
        {:error, :nothing_pending}

      # The first revision is all a new provider has; a new edit replaces
      # it, and removing the provider cancels it.
      %IdentityProvider{active_revision: nil} ->
        {:error, :no_active_revision}

      provider ->
        provider
        |> Ecto.Changeset.change(pending_revision: nil)
        |> save("revision_discarded", actor, revision: provider.pending_revision)
    end)
  end

  @doc """
  Starts a test sign-in of the pending revision for `actor`. Returns
  `{:ok, {token, test}}`; the token opens the test once, within 15 minutes.
  Only a successful test activates a revision (`activate_tested/2`).
  """
  def create_test(%IdentityProvider{id: id} = provider, actor) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    serialized(fn ->
      with {:ok, provider} <- lock(provider),
           number when is_integer(number) <-
             provider.pending_revision || {:error, :nothing_pending} do
        test =
          Repo.insert!(%IdentityProviderTest{
            provider_id: id,
            revision: number,
            token_hash: :crypto.hash(:sha256, token),
            actor: actor_label(actor),
            actor_user_id: actor_user_id(actor),
            expires_at: DateTime.add(Renga.Time.utc_now_ms(), @test_minutes, :minute)
          })

        {:ok, {token, test}}
      end
    end)
  end

  @doc """
  Activates the revision a successful test signed in with, in the same
  transaction that marks the test used. Refused when the test was used or
  expired, or when another edit replaced the revision it tested.
  """
  def activate_tested(%IdentityProviderTest{id: test_id}, tester \\ nil) do
    serialized(fn ->
      with {:ok, test} <- lock_test(test_id),
           # The test was created through a scoped lookup; its provider is
           # whichever scope that was.
           {:ok, provider} <- lock_any(test.provider_id),
           :ok <- authorize_tester(provider, test, tester),
           :ok <- still_pending(provider, test) do
        test |> Ecto.Changeset.change(completed_at: Renga.Time.utc_now_ms()) |> Repo.update!()

        provider
        |> Ecto.Changeset.change(active_revision: test.revision, pending_revision: nil)
        |> save("activated", {:tester, test}, revision: test.revision)
      end
    end)
  end

  defp lock_test(id) do
    now = Renga.Time.utc_now_ms()

    IdentityProviderTest
    |> where(id: ^id)
    |> where([test], is_nil(test.completed_at) and test.expires_at > ^now)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :test_expired}
      test -> {:ok, test}
    end
  end

  # A deployment provider's test is the operator's or an administrator's
  # bearer link and works without a session, as recovery needs. An
  # organization's provider activates only for the owner who created the
  # test, signed in, and still an owner now.
  defp authorize_tester(%IdentityProvider{organization_id: nil}, _test, _tester), do: :ok

  defp authorize_tester(
         %IdentityProvider{organization_id: organization_id},
         %IdentityProviderTest{actor_user_id: user_id},
         %User{id: user_id} = tester
       ) do
    tester
    |> Renga.Accounts.scope_for_user(organization_id)
    |> Renga.Accounts.OrganizationProviders.authorize_owner!()
  end

  defp authorize_tester(_provider, _test, _tester), do: {:error, :forbidden}

  defp still_pending(%IdentityProvider{pending_revision: number}, %IdentityProviderTest{
         revision: number
       }),
       do: :ok

  defp still_pending(_provider, _test), do: {:error, :revision_changed}

  @doc "Turns sign-in through the provider back on."
  def enable(%IdentityProvider{} = provider, actor), do: set_enabled(provider, true, actor)

  @doc """
  Turns sign-in through the provider off. Refused with
  `{:error, :last_sign_in_method}` when it is the deployment's last way to
  sign in.
  """
  def disable(%IdentityProvider{} = provider, actor), do: set_enabled(provider, false, actor)

  defp set_enabled(provider, enabled, actor) do
    Renga.Scim.Grants.announcing(fn -> set_enabled!(provider, enabled, actor) end)
  end

  defp set_enabled!(provider, enabled, actor) do
    change_provider(provider, fn
      %IdentityProvider{enabled: ^enabled} = provider ->
        {:ok, provider}

      provider ->
        provider
        |> Ecto.Changeset.change(enabled: enabled)
        |> save(if(enabled, do: "enabled", else: "disabled"), actor)
        |> scim_changed()
    end)
  end

  @doc """
  Sets the _enforces MFA_ mark and the `amr` combinations the provider
  approves as independent factors (RFD 19), from `attrs` with
  `"enforces_mfa"` and `"mfa_amr_combinations"`. Marking or unmarking is
  recorded as its own event; changing only the combinations is an update.
  The mark applies at each member's next request, so nothing ends here.
  """
  def set_mfa_mark(%IdentityProvider{id: id}, attrs, actor) do
    change_provider(id, fn provider ->
      changeset = IdentityProvider.mfa_changeset(provider, attrs)

      case {changed_fields(changeset), Ecto.Changeset.fetch_change(changeset, :enforces_mfa)} do
        {[], _} -> {:ok, provider}
        {changed, {:ok, true}} -> save(changeset, "mfa_marked", actor, changed: changed)
        {changed, {:ok, false}} -> save(changeset, "mfa_unmarked", actor, changed: changed)
        {changed, :error} -> save(changeset, "updated", actor, changed: changed)
      end
    end)
  end

  @doc """
  Removes the provider. Its ID stays reserved, its revisions lose their
  secrets, and the change is refused when the provider is the deployment's
  last way to sign in.
  """
  def remove(%IdentityProvider{} = provider, actor) do
    Renga.Scim.Grants.announcing(fn -> remove!(provider, actor) end)
  end

  defp remove!(%IdentityProvider{id: id} = provider, actor) do
    change_provider(provider, fn provider ->
      Repo.update_all(where(Revision, provider_id: ^id),
        set: [client_secret_ciphertext: nil, client_secret_key_id: nil]
      )

      provider
      |> Ecto.Changeset.change(
        enabled: false,
        pending_revision: nil,
        removed_at: Renga.Time.utc_now_ms()
      )
      |> save("removed", actor)
      |> scim_changed()
    end)
  end

  @doc "Decrypts a revision's client secret for a request to the provider."
  def client_secret(%Revision{client_secret_ciphertext: nil}), do: {:error, :no_secret}

  def client_secret(%Revision{} = revision) do
    Vault.decrypt(
      revision.client_secret_key_id,
      revision.client_secret_ciphertext,
      secret_aad(revision.provider_id)
    )
  end

  @doc """
  Re-encrypts every saved client secret that is not under the current key,
  so an operator can then retire the old key. Returns how many it rewrote.
  """
  def reencrypt_secrets(actor) do
    case Vault.current_key_id() do
      nil -> {:error, :no_key}
      current -> reencrypt_secrets(current, actor)
    end
  end

  defp reencrypt_secrets(current, actor) do
    serialized(fn ->
      Revision
      |> where([revision], not is_nil(revision.client_secret_ciphertext))
      |> where([revision], revision.client_secret_key_id != ^current)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> reencrypt_all(actor)
    end)
  end

  defp reencrypt_all(revisions, actor) do
    with {:ok, count} <- Enum.reduce_while(revisions, {:ok, 0}, &reencrypt_next(&1, &2, actor)) do
      # A resealed provider is a changed provider: one new version each.
      provider_ids = revisions |> Enum.map(& &1.provider_id) |> Enum.uniq()
      Repo.update_all(where(IdentityProvider, [p], p.id in ^provider_ids), inc: [version: 1])
      {:ok, count}
    end
  end

  defp reencrypt_next(revision, {:ok, count}, actor) do
    case reencrypt(revision, actor) do
      :ok -> {:cont, {:ok, count + 1}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp reencrypt(revision, actor) do
    aad = secret_aad(revision.provider_id)

    with {:ok, secret} <- client_secret(revision),
         {:ok, key_id, ciphertext} <- Vault.encrypt(secret, aad) do
      revision
      |> Ecto.Changeset.change(client_secret_key_id: key_id, client_secret_ciphertext: ciphertext)
      |> Repo.update!()

      record(%IdentityProvider{id: revision.provider_id}, "secret_reencrypted", actor,
        revision: revision.number
      )

      :ok
    end
  end

  @doc "The provider's change history, newest first."
  def list_events(%IdentityProvider{id: id}) do
    IdentityProviderEvent
    |> where(provider_id: ^id)
    |> order_by([event], desc: event.inserted_at, desc: event.id)
    |> Repo.all()
  end

  defp deployment do
    IdentityProvider
    |> where([provider], is_nil(provider.organization_id))
    |> where([provider], is_nil(provider.removed_at))
  end

  defp organization(organization_id) do
    IdentityProvider
    |> where([provider], provider.organization_id == ^organization_id)
    |> where([provider], is_nil(provider.removed_at))
  end

  defp usable_deployment do
    deployment()
    |> where([provider], provider.enabled and not is_nil(provider.active_revision))
  end

  @doc """
  Runs `fun` in a provider-change transaction, holding the lock every
  provider change takes first and, when `provider` is given, its row lock
  in its own scope. For a caller that authorizes the change inside the
  same transaction: its organization locks then come after the
  provider's, in the order SCIM takes them (RFD 16), so neither waits on
  the other. `fun` returns `{:ok, result}` or `{:error, reason}`.
  """
  def locked(nil, fun), do: serialized(fun)

  def locked(%IdentityProvider{} = provider, fun) do
    serialized(fn ->
      with {:ok, _provider} <- lock(provider), do: fun.()
    end)
  end

  # Runs a change under the provider lock, then refuses it if it took away
  # the deployment's last way to sign in. A deployment that has none yet,
  # such as one bootstrapping its first provider with local sign-in off,
  # can still be set up. Every change takes the lock, so the guard sees each
  # one's result before the next begins.
  defp serialized(fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext('renga.identity_providers'))")
      available_before? = sign_in_available?()

      with {:ok, result} <- fun.(),
           true <-
             sign_in_available?() or not available_before? or
               {:error, :last_sign_in_method} do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # SCIM grants through the provider are valid only while it is enabled and
  # not removed (RFD 16), so they change in the same transaction.
  defp scim_changed({:ok, provider}) do
    Renga.Scim.provider_changed!(provider)
    {:ok, provider}
  end

  defp scim_changed(error), do: error

  # Runs `fun` on the locked, current copy of the provider, in the scope of
  # the copy it was given. An ID alone names a deployment provider.
  defp change_provider(%IdentityProvider{} = provider, fun) do
    serialized(fn ->
      with {:ok, provider} <- lock(provider), do: fun.(provider)
    end)
  end

  defp change_provider(id, fun) when is_binary(id),
    do: change_provider(%IdentityProvider{id: id, organization_id: nil}, fun)

  # Saves a provider change with the next version and records it.
  defp save(changeset, kind, actor, opts \\ []) do
    with {:ok, provider} <- changeset |> bump() |> Repo.update() do
      record(provider, kind, actor, opts)
      {:ok, provider}
    end
  end

  defp lock(%IdentityProvider{id: id, organization_id: nil}),
    do: lock_query(where(deployment(), id: ^id))

  defp lock(%IdentityProvider{id: id, organization_id: organization_id}),
    do: lock_query(where(organization(organization_id), id: ^id))

  defp lock_any(id),
    do: lock_query(from(p in IdentityProvider, where: p.id == ^id and is_nil(p.removed_at)))

  defp lock_query(query) do
    case Repo.one(lock(query, "FOR UPDATE")) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  defp bump(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.put_change(changeset, :version, changeset.data.version + 1)
  end

  defp next_revision_number(%IdentityProvider{id: id}) do
    Revision
    |> where(provider_id: ^id)
    |> select([revision], max(revision.number))
    |> Repo.one()
    |> Kernel.+(1)
  end

  defp insert_revision(changeset, provider, number, actor) do
    changeset =
      changeset
      |> Ecto.Changeset.put_change(:provider_id, provider.id)
      |> Ecto.Changeset.put_change(:number, number)
      |> Ecto.Changeset.put_change(:created_by, actor_label(actor))

    with {:ok, changeset} <- encrypt_secret(changeset, provider.id) do
      Repo.insert(changeset)
    end
  end

  defp encrypt_secret(%Ecto.Changeset{valid?: false} = changeset, _id), do: {:ok, changeset}

  defp encrypt_secret(changeset, id) do
    case Ecto.Changeset.get_change(changeset, :client_secret) do
      nil ->
        {:ok, changeset}

      secret ->
        case Vault.encrypt(secret, secret_aad(id)) do
          {:ok, key_id, ciphertext} ->
            {:ok,
             changeset
             |> Ecto.Changeset.delete_change(:client_secret)
             |> Ecto.Changeset.put_change(:client_secret_ciphertext, ciphertext)
             |> Ecto.Changeset.put_change(:client_secret_key_id, key_id)
             |> Ecto.Changeset.put_change(:client_secret_set_at, Renga.Time.utc_now_ms())}

          {:error, :no_key} ->
            {:error, :no_encryption_key}
        end
    end
  end

  # The secret is bound to its provider, so a ciphertext copied to another
  # provider's row does not decrypt.
  defp secret_aad(provider_id), do: "identity_provider:#{provider_id}:client_secret"

  defp changed_fields(%Ecto.Changeset{changes: changes}) do
    changes |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  # Reports both changesets' errors at once, on the provider's.
  defp merge_errors(provider_changeset, revision_changeset) do
    Enum.reduce(revision_changeset.errors, %{provider_changeset | action: :insert}, fn
      {field, {message, keys}}, changeset ->
        Ecto.Changeset.add_error(changeset, field, message, keys)
    end)
  end

  defp record(provider, kind, actor, opts) do
    Repo.insert!(%IdentityProviderEvent{
      provider_id: provider.id,
      kind: kind,
      revision: opts[:revision],
      changed: Keyword.get(opts, :changed, []),
      actor: actor_label(actor),
      actor_user_id: actor_user_id(actor)
    })

    record_activity(provider, kind, actor, opts)
  end

  # An organization's provider changes show in that organization's
  # Activity too, with the fields that changed and never a secret.
  defp record_activity(%IdentityProvider{organization_id: nil}, _kind, _actor, _opts), do: :ok

  defp record_activity(
         %IdentityProvider{organization_id: organization_id} = provider,
         kind,
         actor,
         opts
       ) do
    %ChangeEvent{organization_id: organization_id, actor_user_id: actor_user_id(actor)}
    |> ChangeEvent.changeset(%{
      kind: "identity_provider_changed",
      field: provider.id,
      metadata: %{
        "provider" => provider.id,
        "name" => provider.display_name,
        "change" => kind,
        "revision" => opts[:revision],
        "changed" => Keyword.get(opts, :changed, [])
      },
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()

    :ok
  end

  defp actor_label({:user, %User{email: email}}) when is_binary(email), do: email
  defp actor_label({:user, %User{id: id}}), do: "user: #{id}"
  defp actor_label({:operator, name}) when is_binary(name), do: "operator: #{name}"
  # Whoever asked for a test is the actor of the activation it leads to.
  defp actor_label({:tester, %IdentityProviderTest{actor: actor}}), do: actor

  defp actor_user_id({:user, %User{id: id}}), do: id
  defp actor_user_id({:operator, _name}), do: nil
  defp actor_user_id({:tester, %IdentityProviderTest{actor_user_id: id}}), do: id
end
