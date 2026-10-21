defmodule Renga.Accounts.IdentityProviders do
  @moduledoc """
  Deployment identity providers stored in the database (RFD 15, "Storage and
  changes"). Release commands and the operator API (RFD 22) both manage
  providers through this module, so there is one store and one set of rules.

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
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderEvent
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.SignInPolicy
  alias Renga.Accounts.User
  alias Renga.Repo
  alias Renga.Vault

  @doc "The deployment's providers that have not been removed, by display name."
  def list do
    deployment()
    |> order_by([provider], asc: provider.display_name, asc: provider.id)
    |> Repo.all()
  end

  @doc "A deployment provider by ID, or nil when there is none or it was removed."
  def get(id) when is_binary(id), do: Repo.get(deployment(), id)

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
  Adds a deployment provider. Its settings become revision 1, pending until
  a test sign-in activates it, so a new provider takes no sign-ins yet.
  """
  def create(attrs, actor) do
    provider_changeset = IdentityProvider.create_changeset(%IdentityProvider{}, attrs)
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
  def update_display(%IdentityProvider{id: id}, attrs, actor) do
    change_provider(id, fn provider ->
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
  def propose_revision(%IdentityProvider{id: id}, attrs, actor) do
    change_provider(id, &propose(&1, attrs, actor))
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
  def discard_pending(%IdentityProvider{id: id}, actor) do
    change_provider(id, fn
      %IdentityProvider{pending_revision: nil} ->
        {:error, :nothing_pending}

      provider ->
        provider
        |> Ecto.Changeset.change(pending_revision: nil)
        |> save("revision_discarded", actor, revision: provider.pending_revision)
    end)
  end

  @doc "Turns sign-in through the provider back on."
  def enable(%IdentityProvider{id: id}, actor), do: set_enabled(id, true, actor)

  @doc """
  Turns sign-in through the provider off. Refused with
  `{:error, :last_sign_in_method}` when nothing else could sign in.
  """
  def disable(%IdentityProvider{id: id}, actor), do: set_enabled(id, false, actor)

  defp set_enabled(id, enabled, actor) do
    change_provider(id, fn
      %IdentityProvider{enabled: ^enabled} = provider ->
        {:ok, provider}

      provider ->
        provider
        |> Ecto.Changeset.change(enabled: enabled)
        |> save(if(enabled, do: "enabled", else: "disabled"), actor)
    end)
  end

  @doc """
  Removes the provider. Its ID stays reserved, its revisions lose their
  secrets, and the change is refused when nothing else could sign in.
  """
  def remove(%IdentityProvider{id: id}, actor) do
    change_provider(id, fn provider ->
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
    current = Vault.current_key_id()

    serialized(fn ->
      Revision
      |> where([revision], not is_nil(revision.client_secret_ciphertext))
      |> where([revision], revision.client_secret_key_id != ^current)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.reduce_while({:ok, 0}, &reencrypt_next(&1, &2, actor))
    end)
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

  defp usable_deployment do
    deployment()
    |> where([provider], provider.enabled and not is_nil(provider.active_revision))
  end

  # Runs a change under the provider lock, then refuses it if it left the
  # deployment with no way to sign in. Every change takes the lock, so the
  # guard sees each one's result before the next begins.
  defp serialized(fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext('renga.identity_providers'))")

      with {:ok, result} <- fun.(),
           true <- sign_in_available?() || {:error, :last_sign_in_method} do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Runs `fun` on the locked, current copy of the provider.
  defp change_provider(id, fun) do
    serialized(fn ->
      with {:ok, provider} <- lock(id), do: fun.(provider)
    end)
  end

  # Saves a provider change with the next version and records it.
  defp save(changeset, kind, actor, opts \\ []) do
    with {:ok, provider} <- changeset |> bump() |> Repo.update() do
      record(provider, kind, actor, opts)
      {:ok, provider}
    end
  end

  defp lock(id) do
    case Repo.one(from(provider in deployment(), where: provider.id == ^id, lock: "FOR UPDATE")) do
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
  end

  defp actor_label({:user, %User{email: email}}), do: email
  defp actor_label({:operator, name}) when is_binary(name), do: "operator: #{name}"

  defp actor_user_id({:user, %User{id: id}}), do: id
  defp actor_user_id({:operator, _name}), do: nil
end
