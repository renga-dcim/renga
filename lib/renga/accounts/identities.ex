defmodule Renga.Accounts.Identities do
  @moduledoc """
  Resolves a validated provider sign-in to a Renga account (RFD 15,
  "Identities and accounts").

  A returning sign-in matches on the provider and subject only, never on
  email, because addresses are reassigned. A first sign-in never links to an
  existing account with the same email, even a verified one: that person
  signs in to the account and links the provider there. Otherwise a provider
  that allows sign-up creates a confirmed account from a verified email, and
  any other first sign-in is refused.

  A sign-in also links the SCIM directory entries that correlate with the
  ID token (RFD 16), and an active entry opens sign-up for a person whose
  provider does not otherwise allow it (`Renga.Scim.Linking`).

  A signed-in person links a provider from their settings after the account
  re-check (`link/2`), and unlinks one the same way (`unlink/3`), which never
  takes away their last way to sign in.
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.MFA
  alias Renga.Accounts.Recheck
  alias Renga.Accounts.SecurityLog
  alias Renga.Accounts.SignInPolicy
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Repo
  alias Renga.Scim.Linking

  @doc "The account's linked identities with their providers, by provider name."
  def list(%User{id: user_id}) do
    UserIdentity
    |> where(user_id: ^user_id)
    |> join(:inner, [identity], provider in assoc(identity, :provider))
    |> order_by([identity, provider], asc: provider.display_name, asc: identity.inserted_at)
    |> preload([identity, provider], provider: provider)
    |> Repo.all()
  end

  @doc """
  The deployment providers `user` could link from settings: usable, shown on
  the sign-in page, and OpenID Connect, the only kind that can sign in yet.
  """
  def linkable_providers(%User{} = user) do
    linked = user |> list() |> MapSet.new(& &1.provider_id)

    IdentityProviders.sign_in_options()
    |> Enum.filter(&(&1.kind == "oidc" and not MapSet.member?(linked, &1.id)))
  end

  @doc """
  Links the identity a validated link attempt returned (`OIDC.finish/4`) to
  `user`. The attempt is already bound to this user's session and was
  started after the account re-check. Under a share lock on the provider,
  like a sign-in, it checks the provider still uses the attempt's revision.
  Returns `{:ok, identity}` or `{:error, reason}`, where `reason` is
  `:invalid_claims`, `:domain_not_allowed`, `:already_linked` (to this
  account), `:linked_elsewhere` (to another), or a provider change.
  """
  def link(%User{} = user, %{provider: provider, revision: %Revision{} = revision, claims: claims}) do
    email = email(claims)

    Repo.transaction(fn ->
      with :ok <- lock_current(provider, revision),
           {:ok, subject} <- subject(claims),
           :ok <- check_domain(revision, email),
           :ok <- check_unlinked(provider, subject, user),
           {:ok, identity} <- insert_link(user, provider, subject, email) do
        SecurityLog.record(user, "identity_linked", %{"provider" => provider.id})
        %{identity | provider: provider}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> tap(fn result ->
      with {:ok, _identity} <- result, do: SecurityLog.notify(user, "identity_linked")
    end)
  end

  defp lock_current(provider, revision) do
    current =
      Repo.one(
        from p in IdentityProvider,
          where: p.id == ^provider.id and is_nil(p.removed_at) and is_nil(p.organization_id),
          lock: "FOR SHARE"
      )

    case current do
      %{enabled: true, active_revision: number} when number == revision.number -> :ok
      %{enabled: true} -> {:error, :provider_changed}
      _disabled_or_removed -> {:error, :inactive}
    end
  end

  defp check_unlinked(provider, subject, %User{id: user_id}) do
    case Repo.get_by(UserIdentity, provider_id: provider.id, subject: subject) do
      nil -> :ok
      %UserIdentity{user_id: ^user_id} -> {:error, :already_linked}
      %UserIdentity{} -> {:error, :linked_elsewhere}
    end
  end

  defp insert_link(user, provider, subject, email) do
    %UserIdentity{user_id: user.id, provider_id: provider.id, subject: subject}
    |> Ecto.Changeset.change(email: email && email.address)
    |> Ecto.Changeset.unique_constraint([:provider_id, :subject])
    |> Repo.insert()
    |> case do
      {:ok, identity} -> {:ok, identity}
      # Someone linked or signed up with the same subject meanwhile.
      {:error, _changeset} -> {:error, :linked_elsewhere}
    end
  end

  @doc """
  Unlinks one of the account's identities, if the browser session holding
  `session_token` passed the account re-check. Refused with
  `{:error, :last_sign_in_method}` when the account could no longer sign in
  under the deployment's local sign-in policy and providers.
  """
  def unlink(%User{} = user, session_token, identity_id) do
    MFA.with_account_lock(user, fn ->
      with true <-
             Recheck.authorized?(user, session_token, :unlink_identity) ||
               {:error, :recheck_required},
           %UserIdentity{} = identity <-
             Repo.one(
               from i in UserIdentity,
                 where: i.id == ^identity_id and i.user_id == ^user.id,
                 preload: :provider
             ) || {:error, :not_found},
           true <- can_sign_in_without?(user, identity) || {:error, :last_sign_in_method} do
        Repo.delete!(identity)
        SecurityLog.record(user, "identity_unlinked", %{"provider" => identity.provider_id})
        {:ok, identity}
      end
    end)
    |> tap(fn result ->
      with {:ok, _identity} <- result, do: SecurityLog.notify(user, "identity_unlinked")
    end)
  catch
    # A malformed ID from a crafted event names no identity.
    :error, %Ecto.Query.CastError{} -> {:error, :not_found}
  end

  # With local sign-in on, the account's email still signs it in. Otherwise
  # another identity at a usable deployment provider must.
  defp can_sign_in_without?(user, identity) do
    SignInPolicy.local_sign_in?() or
      Repo.exists?(
        from i in UserIdentity,
          join: p in assoc(i, :provider),
          where: i.user_id == ^user.id and i.id != ^identity.id,
          where: is_nil(p.organization_id) and is_nil(p.removed_at),
          where: p.enabled and not is_nil(p.active_revision)
      )
  end

  @doc """
  The account for a validated sign-in, as `OIDC.finish/3` returns it.
  Returns `{:ok, user}` or `{:error, reason}`, where `reason` is
  `:invalid_claims`, `:domain_not_allowed`, `:email_in_use`,
  `:unverified_email`, or `:sign_up_closed`.
  """
  def resolve(%{provider: provider, revision: %Revision{} = revision, claims: claims}) do
    email = email(claims)

    with {:ok, subject} <- subject(claims),
         :ok <- check_domain(revision, email) do
      case Repo.get_by(UserIdentity, provider_id: provider.id, subject: subject) do
        %UserIdentity{} = identity -> {:ok, returning(identity, email, claims)}
        nil -> first_sign_in(provider, revision, subject, email, claims)
      end
    end
  end

  defp returning(identity, email, claims) do
    identity =
      identity
      |> Ecto.Changeset.change(
        email: email && email.address,
        last_signed_in_at: Renga.Time.utc_now_ms()
      )
      |> Repo.update!()

    Linking.link_identity(identity, claims)

    Repo.get!(User, identity.user_id)
  end

  defp first_sign_in(provider, revision, subject, email, claims) do
    # Only a verified address is said to be in use, so an unverified claim
    # cannot ask whether an account exists.
    cond do
      email && email.verified && Repo.get_by(User, email: email.address) ->
        {:error, :email_in_use}

      not revision.allow_sign_up and not Linking.permits_sign_up?(provider, claims) ->
        {:error, :sign_up_closed}

      is_nil(email) or not email.verified ->
        {:error, :unverified_email}

      true ->
        sign_up(provider, subject, email.address, claims)
    end
  end

  defp sign_up(provider, subject, address, claims) do
    Repo.transact(fn ->
      with {:ok, user} <-
             %User{}
             |> User.email_changeset(%{email: address})
             |> Ecto.Changeset.put_change(:confirmed_at, Renga.Time.utc_now_ms())
             |> Repo.insert() do
        link_new_user(user, provider, subject, address, claims)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, :already_linked} -> {:error, :already_linked}
      {:error, %Ecto.Changeset{} = changeset} -> sign_up_error(changeset)
    end
  end

  defp link_new_user(user, provider, subject, address, claims) do
    %UserIdentity{
      user_id: user.id,
      provider_id: provider.id,
      subject: subject,
      email: address,
      last_signed_in_at: Renga.Time.utc_now_ms()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint([:provider_id, :subject])
    |> Repo.insert()
    |> case do
      {:ok, identity} ->
        Linking.link_identity(identity, claims)
        {:ok, user}

      # A concurrent first sign-in by the same subject linked it first.
      {:error, _changeset} ->
        {:error, :already_linked}
    end
  end

  # Only a collision means the address is taken; any other problem with it,
  # such as its length, makes the claims unusable.
  defp sign_up_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
         opts[:constraint] == :unique or opts[:validation] == :unsafe_unique
       end),
       do: {:error, :email_in_use},
       else: {:error, :invalid_claims}
  end

  # The allowlist limits who may sign in at all, so it applies to returning
  # sign-ins too, and only a verified address satisfies it.
  defp check_domain(%Revision{email_domains: []}, _email), do: :ok

  defp check_domain(%Revision{email_domains: domains}, %{verified: true, domain: domain}) do
    if domain in domains, do: :ok, else: {:error, :domain_not_allowed}
  end

  defp check_domain(_revision, _email), do: {:error, :domain_not_allowed}

  defp subject(%{"sub" => subject})
       when is_binary(subject) and subject != "" and byte_size(subject) <= 255,
       do: {:ok, subject}

  defp subject(_claims), do: {:error, :invalid_claims}

  defp email(%{"email" => address} = claims) when is_binary(address) do
    address = address |> String.trim() |> String.downcase()

    case String.split(address, "@") do
      [local, domain] when local != "" and domain != "" ->
        %{address: address, domain: domain, verified: claims["email_verified"] in [true, "true"]}

      _other ->
        nil
    end
  end

  defp email(_claims), do: nil
end
