defmodule Renga.Accounts do
  @moduledoc """
  Accounts and organization tenancy boundaries.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Identities
  alias Renga.Accounts.Organization
  alias Renga.Accounts.OrganizationMembership
  alias Renga.Accounts.MFA
  alias Renga.Accounts.Passkeys
  alias Renga.Accounts.Recheck
  alias Renga.Accounts.Scope
  alias Renga.Accounts.SecurityLog
  alias Renga.Accounts.SignInPolicy
  alias Renga.Accounts.User
  alias Renga.Accounts.UserNotifier
  alias Renga.Accounts.UserToken
  alias Renga.Authorization
  alias Renga.Repo

  @doc """
  Builds a scope for context calls that must be organization-bound.

  Use this when background jobs, API authentication, or tests already know the
  organization and need to call organization-scoped contexts without a browser
  session.
  """
  def scope_for(%Organization{} = organization, attrs \\ %{}) do
    Scope.new(organization, attrs)
  end

  @doc """
  Lists organizations for administrative workflows.
  """
  def list_organizations do
    Repo.all(from organization in Organization, order_by: [asc: organization.name])
  end

  @doc """
  Fetches an organization by id when the caller has already handled scoping.
  """
  def get_organization!(id), do: Repo.get!(Organization, id)

  @doc """
  Fetches an organization by slug for future tenant selection flows.
  """
  def get_organization_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Organization, slug: slug)
  end

  @doc """
  Creates an organization, the root tenant boundary for inventory data.
  """
  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates an organization and its initial owner membership atomically.

  This is the browser onboarding boundary: a signed-in user cannot enter an
  organization-scoped inventory view until they own or join an organization.
  A session scoped to one organization (RFD 15) cannot create another:
  `{:error, :scoped_session}`.
  """
  def create_organization_for_user(%User{session_organization_id: id}, _attrs)
      when is_binary(id),
      do: {:error, :scoped_session}

  def create_organization_for_user(%User{} = user, attrs) do
    Repo.transaction(fn ->
      with {:ok, organization} <- create_organization(attrs),
           {:ok, membership} <-
             create_organization_membership(organization, %{
               user_id: user.id,
               role: "owner"
             }) do
        {organization, membership}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Updates organization metadata without changing membership or inventory scope.
  """
  def update_organization(%Organization{} = organization, attrs) do
    organization
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Changes the accent an organization's members see until they choose
  their own (RFD 8, "Visual design"). Needs `organization.manage`.
  """
  def set_default_accent(%Scope{user: %User{}, organization_id: organization_id} = scope, accent)
      when is_binary(organization_id) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, "organization.manage")

      Organization
      |> Repo.get!(organization_id)
      |> Organization.default_accent_changeset(%{default_accent: accent})
      |> Repo.update()
      |> case do
        {:ok, organization} -> organization
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def set_default_accent(_scope, _accent), do: {:error, :forbidden}

  @doc """
  Builds an organization changeset for forms and validations.
  """
  def change_organization(%Organization{} = organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
  end

  @doc """
  Lists memberships inside one organization boundary.
  """
  def list_organization_memberships(%Organization{} = organization) do
    list_organization_memberships(scope_for(organization))
  end

  def list_organization_memberships(%Scope{organization_id: organization_id}) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> order_by([membership], asc: membership.user_id)
    |> Repo.all()
  end

  @doc """
  Active members of the caller's organization who hold `permission`, through
  their base role or an assignment, users preloaded and ordered by email, for
  pickers such as a finding's assignee.
  """
  def list_active_members(%Scope{organization_id: organization_id}, permission) do
    OrganizationMembership
    |> join(:inner, [membership], user in assoc(membership, :user))
    |> where([membership], membership.organization_id == ^organization_id)
    |> where([membership], membership.status == "active")
    |> Authorization.holding(permission)
    |> order_by([_membership, user], asc: user.email)
    |> preload([_membership, user], user: user)
    |> Repo.all()
  end

  @doc """
  Fetches a membership only when it belongs to the caller's organization scope.
  """
  def get_organization_membership!(%Scope{organization_id: organization_id}, id) do
    OrganizationMembership
    |> where([membership], membership.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  @doc """
  Finds a user's membership in one organization for authorization decisions.
  """
  def get_membership_for_user(%Organization{} = organization, user_id) do
    get_membership_for_user(scope_for(organization), user_id)
  end

  def get_membership_for_user(%Scope{organization_id: organization_id}, user_id)
      when is_binary(user_id) do
    Repo.get_by(OrganizationMembership, organization_id: organization_id, user_id: user_id)
  end

  @doc """
  Adds a user to an organization.

  The organization id is set by the trusted argument, not caller attrs, so a
  form/API caller cannot smuggle membership into another tenant.
  """
  def create_organization_membership(%Organization{} = organization, attrs) do
    create_organization_membership(scope_for(organization), attrs)
  end

  def create_organization_membership(%Scope{organization_id: organization_id}, attrs) do
    %OrganizationMembership{organization_id: organization_id}
    |> OrganizationMembership.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates membership role/status while preserving its organization and user ids.
  """
  def update_organization_membership(%OrganizationMembership{} = membership, attrs) do
    membership
    |> OrganizationMembership.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists active organization memberships a signed-in user can select. A
  user loaded from an organization-scoped session (RFD 15) can select only
  that organization.
  """
  def list_user_organization_memberships(%User{} = user) do
    OrganizationMembership
    |> join(:inner, [membership], organization in assoc(membership, :organization))
    |> where([membership, organization], membership.user_id == ^user.id)
    |> where([membership, organization], membership.status == "active")
    |> where([membership, organization], organization.status == "active")
    |> within_session_organization(user)
    |> preload([membership, organization], organization: organization)
    |> order_by([membership, organization], asc: organization.name)
    |> Repo.all()
  end

  @doc """
  Returns the active membership only if the user can access the organization.
  """
  def get_user_organization_membership(%User{} = user, organization_id)
      when is_binary(organization_id) do
    OrganizationMembership
    |> join(:inner, [membership], organization in assoc(membership, :organization))
    |> where([membership, organization], membership.user_id == ^user.id)
    |> where([membership, organization], membership.organization_id == ^organization_id)
    |> where([membership, organization], membership.status == "active")
    |> where([membership, organization], organization.status == "active")
    |> within_session_organization(user)
    |> preload([membership, organization], organization: organization)
    |> Repo.one()
  end

  def get_user_organization_membership(%User{}, _organization_id), do: nil

  defp within_session_organization(query, %User{session_organization_id: nil}), do: query

  defp within_session_organization(query, %User{session_organization_id: organization_id}),
    do: where(query, [membership], membership.organization_id == ^organization_id)

  @doc """
  The organization to open when `user` signs in: `remembered_id`, the one
  this browser last opened, if they can still open it, or else their only
  organization. Returns nil when they have several and none remembered, so
  they choose.
  """
  def default_organization_id(%User{} = user, remembered_id) do
    if get_user_organization_membership(user, remembered_id) do
      remembered_id
    else
      case list_user_organization_memberships(user) do
        [membership] -> membership.organization_id
        _none_or_several -> nil
      end
    end
  end

  @doc """
  Builds the request scope from the signed-in user and selected organization.

  An invalid or absent organization id intentionally falls back to user-only
  scope instead of granting access to a tenant.
  """
  def scope_for_user(user, organization_id \\ nil)

  def scope_for_user(%User{} = user, organization_id) when organization_id in [nil, ""] do
    Scope.for_user(user)
  end

  def scope_for_user(%User{} = user, organization_id) do
    membership = get_user_organization_membership(user, organization_id)

    case membership do
      %OrganizationMembership{organization: %Organization{} = organization} ->
        assigned = Authorization.assigned_access(membership.id)
        Scope.for_membership(user, organization, membership, assigned)

      _ ->
        Scope.for_user(user)
    end
  end

  def scope_for_user(nil, _organization_id), do: Scope.for_user(nil)

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Gets a single user, or `nil`."
  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Whether the browser session may make an account-takeover `change` now. See
  `Renga.Accounts.Recheck`.
  """
  defdelegate authorized_account_change?(user, session_token, change),
    to: Recheck,
    as: :authorized?

  @doc "The ways `user` can pass the account re-check."
  defdelegate recheck_methods(user), to: Recheck, as: :methods

  @doc "The account's identities that can pass the re-check by signing in again."
  defdelegate recheck_identities(user), to: Recheck, as: :provider_identities

  @doc "Records an account re-check for this session from a validated provider re-check."
  defdelegate recheck_with_provider(user, session_token, identity_id, result), to: Recheck

  @doc "Records an account re-check for this session if `password` is correct."
  defdelegate recheck_with_password(user, session_token, password), to: Recheck

  @doc "Records an account re-check for this session if `code` is a good authenticator code."
  defdelegate recheck_with_totp(user, session_token, code), to: Recheck

  @doc "Emails the first-password or first-factor bootstrap code."
  defdelegate deliver_bootstrap_code(user, session_token), to: Recheck

  @doc """
  Issues a session for `browser_session_id` that holds RFD 19's bootstrap
  authorization, for a person who just proved control of the email to add
  a first credential. Eligibility (no re-check method at all), the session
  and the grant are one transaction under the account lock, so a factor
  added meanwhile means no session is issued: `:error`, and the caller
  signs in the usual way, with the second step if one is needed now.
  """
  def create_bootstrap_session(%User{id: user_id}, browser_session_id) do
    MFA.with_account_lock(%User{id: user_id}, fn ->
      user = Repo.get!(User, user_id)

      if Recheck.methods(user) == [] do
        token = generate_user_session_token(user, browser_session_id)
        :ok = Recheck.start_bootstrap(user, token)
        record_issued_sign_in(user, "magic_link")
        {:ok, token}
      else
        {:error, :not_available}
      end
    end)
    |> case do
      {:ok, token} when is_binary(token) -> {:ok, token}
      _ -> :error
    end
  end

  @doc "Spends a bootstrap code for this session."
  defdelegate verify_bootstrap_code(user, session_token, code), to: Recheck

  ## Second factors

  @doc """
  Adds an authenticator app once `code` proves it, if this session passed
  the account re-check (or, for an account with no credential yet, the
  email bootstrap). Returns new recovery codes when it is the first factor.
  """
  def add_totp(%User{} = user, session_token, secret, code) do
    cond do
      # Recovery replaces a lost app once: the grant is spent in the same
      # locked transaction that saves the replacement.
      Recheck.recovering?(user, session_token) ->
        with {:ok, codes} <-
               MFA.enable_totp(user, secret, code,
                 replace: true,
                 authorize: fn -> Recheck.spend_recovery(user, session_token) end
               ) do
          notify_factor_added(user, "totp_added", codes)
        end

      Recheck.authorized?(user, session_token, :add_factor) ->
        with {:ok, codes} <- MFA.enable_totp(user, secret, code) do
          notify_factor_added(user, "totp_added", codes)
        end

      true ->
        {:error, :recheck_required}
    end
  end

  @doc "Records an account re-check for this session from a passkey assertion."
  defdelegate recheck_with_passkey(user, session_token, response), to: Recheck

  @doc """
  Adds a passkey from the browser's registration response, if this session
  passed the re-check, is bootstrapping its first credential, or is
  recovering. Returns the passkey and, when it is the first factor, new
  recovery codes.
  """
  def add_passkey(%User{} = user, session_token, response, name) do
    # A recovering session spends its grant on this passkey; otherwise the
    # re-check is checked again under the lock.
    authorize =
      if Recheck.recovering?(user, session_token),
        do: fn -> Recheck.spend_recovery(user, session_token) end,
        else: fn -> Recheck.authorized?(user, session_token, :add_factor) end

    with {:ok, {passkey, codes}} <-
           MFA.add_factor(user, fn -> Passkeys.register(user, response, name) end, authorize) do
      notify_factor_added(user, "passkey_added", codes)
      {:ok, passkey, codes}
    end
  end

  # The first factor also brings the first recovery codes.
  defp notify_factor_added(user, kind, codes) do
    SecurityLog.notify(user, kind)
    if codes, do: SecurityLog.notify(user, "recovery_codes_generated")
    {:ok, codes}
  end

  @doc "Removes a passkey if this session passed the re-check."
  def remove_passkey(%User{} = user, session_token, passkey_id) do
    MFA.remove_factor(
      user,
      fn ->
        # A passwordless account keeps a credential it can sign in with.
        # Read under the account lock, so a concurrent password removal or
        # passkey removal cannot leave it with none.
        if is_nil(Repo.get!(User, user.id).hashed_password) and length(Passkeys.list(user)) == 1,
          do: {:error, :last_passkey},
          else: Passkeys.delete(user, passkey_id)
      end,
      fn -> Recheck.authorized?(user, session_token, :remove_factor) end
    )
    |> tap(fn result ->
      with {:ok, _passkey} <- result, do: SecurityLog.notify(user, "passkey_removed")
    end)
  end

  @doc """
  Removes the password from an account that has a passkey, after the
  re-check (RFD 19, "Passwordless accounts").
  """
  def remove_user_password(%User{} = user, session_token) do
    # Under the account lock, like removing a passkey, so the two cannot
    # race to leave the account with neither.
    MFA.with_account_lock(user, fn ->
      cond do
        not Recheck.authorized?(user, session_token, :set_password) ->
          {:error, :recheck_required}

        not Passkeys.any?(user) ->
          {:error, :no_passkey}

        true ->
          user =
            User
            |> Repo.get!(user.id)
            |> Ecto.Changeset.change(hashed_password: nil)
            |> Repo.update!()

          SecurityLog.record(user, "password_removed")

          # A sign-in half-finished with the password ends with it.
          Repo.delete_all(
            from token in UserToken,
              where: token.user_id == ^user.id and token.context == "second_step"
          )

          {:ok, user}
      end
    end)
    |> tap(fn result ->
      with {:ok, user} <- result, do: SecurityLog.notify(user, "password_removed")
    end)
  end

  @doc "Options for signing in with any of this site's passkeys, including autofill."
  def passkey_sign_in_options, do: Passkeys.authentication_options("sign_in")

  @doc "Options for a passkey ceremony that only `user`'s passkeys can complete."
  def passkey_options(%User{} = user, purpose) when purpose in ["second_step", "recheck"],
    do: Passkeys.authentication_options(purpose, user)

  @doc "Options for registering a new passkey for `user`."
  defdelegate passkey_registration_options(user), to: Passkeys, as: :registration_options

  @doc "The account's passkeys."
  defdelegate list_passkeys(user), to: Passkeys, as: :list

  @doc "Renames one of the account's passkeys."
  defdelegate rename_passkey(user, passkey_id, name), to: Passkeys, as: :rename

  @doc "Signs in with a discoverable passkey, which needs no second step."
  def get_user_by_passkey(response) when is_map(response) do
    case Passkeys.authenticate("sign_in", response) do
      {:ok, user, _passkey} -> user
      {:error, _reason} -> nil
    end
  end

  @doc "Whether this session signed in with a recovery code and may replace a factor."
  defdelegate recovering?(user, session_token), to: Recheck

  @doc """
  Completes the second step of signing in (RFD 19) with an authenticator
  code, a passkey assertion (`{:passkey, response}`), or, failing those, a
  recovery code. Returns `{:ok, method}`.
  """
  def verify_second_step(%User{} = user, {:passkey, response}) do
    with {:ok, _user, _passkey} <- Passkeys.authenticate("second_step", response, user),
         do: {:ok, :passkey}
  end

  def verify_second_step(%User{} = user, code) when is_binary(code) do
    if String.match?(String.replace(code, ~r/\s/, ""), ~r/^\d{6}$/) do
      with :ok <- MFA.verify_totp(user, code), do: {:ok, :totp}
    else
      with :ok <- MFA.spend_recovery_code(user, code) do
        SecurityLog.notify(user, "recovery_code_used")
        {:ok, :recovery_code}
      end
    end
  end

  @doc """
  Records a completed sign-in in the account's security log. `method` is
  how it finished: `"password"`, `"magic_link"`, `"passkey"`, `"totp"`, or
  `"recovery_code"`.
  """
  def record_sign_in(%User{} = user, method),
    do: SecurityLog.record(user, "signed_in", %{"method" => method})

  # Records a sign-in in the transaction that issues its session. A local
  # credential (anything but a provider) signs in only while the local
  # sign-in policy allows it, checked here rather than only before the
  # transaction, so a sign-in racing a revoked override issues nothing. A
  # sign-in an override allowed names it in the log (RFD 15).
  defp record_issued_sign_in(user, "provider:" <> _ = method), do: record_sign_in(user, method)

  defp record_issued_sign_in(user, method) do
    case SignInPolicy.local_sign_in_grant() do
      {:ok, nil} ->
        record_sign_in(user, method)

      {:ok, override_id} ->
        SecurityLog.record(user, "signed_in", %{
          "method" => method,
          "local_override" => override_id
        })

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @doc """
  Issues a session for a fresh sign-in by `method` and records the sign-in
  in the same transaction, so the log never shows a sign-in whose session
  was not created. Returns `:error`, issuing nothing, when the local sign-in
  policy refuses a local `method`.
  """
  def create_signed_in_session(%User{} = user, browser_session_id, method, expires_at \\ nil) do
    Repo.transact(fn ->
      record_issued_sign_in(user, method)
      {:ok, generate_user_session_token(user, browser_session_id, expires_at)}
    end)
    |> case do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> :error
    end
  end

  @doc """
  When the session `token` ends regardless of activity, or nil. Only a
  session from a provider sign-in has such a deadline (RFD 15).
  """
  def session_deadline(token) when is_binary(token) do
    Repo.one(
      from t in UserToken,
        where: t.token == ^token and t.context == "session",
        select: t.expires_at
    )
  end

  @doc """
  Finishes a provider sign-in that `OIDC.finish/3` validated. Under a share
  lock on the provider, so it cannot be disabled, removed, or given another
  active revision meanwhile, it checks the provider still uses the revision
  the attempt started with, resolves the account, and runs `issue` with it.
  `issue` creates the session and returns `{:ok, value}`; anything else rolls
  the whole sign-in back, an account it would have created included.
  """
  def finish_provider_sign_in(%{provider: provider, revision: revision} = result, issue) do
    # A sign-in may link SCIM entries and so change grants (RFD 16).
    Renga.Scim.Grants.announcing(fn -> provider_sign_in(provider, revision, result, issue) end)
  end

  defp provider_sign_in(provider, revision, result, issue) do
    Repo.transaction(fn ->
      current =
        Repo.one(
          from p in Renga.Accounts.IdentityProvider,
            where: p.id == ^provider.id and is_nil(p.removed_at) and is_nil(p.organization_id),
            lock: "FOR SHARE"
        )

      with %{enabled: true} <- current || {:error, :inactive},
           %{active_revision: number} when number == revision.number <- current,
           {:ok, user} <- Renga.Accounts.Identities.resolve(result),
           {:ok, value} <- issue.(user) do
        value
      else
        %{enabled: false} -> Repo.rollback(:inactive)
        %{} -> Repo.rollback(:provider_changed)
        {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
        _other -> Repo.rollback(:session_failed)
      end
    end)
  end

  ## Linked identities

  @doc "The account's linked provider identities. See `Renga.Accounts.Identities`."
  defdelegate list_user_identities(user), to: Identities, as: :list

  @doc "The deployment providers the account could link from settings."
  defdelegate linkable_providers(user), to: Identities

  @doc "Links the identity a validated link attempt returned to the account."
  defdelegate link_identity(user, result), to: Identities, as: :link

  @doc "Unlinks one of the account's identities if this session passed the re-check."
  defdelegate unlink_identity(user, session_token, identity_id), to: Identities, as: :unlink

  @doc """
  The ID of the session token `token`, while it is a valid session of
  `user`, for binding something to that session; otherwise nil.
  """
  def session_token_id(%User{id: user_id}, token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    query
    |> where([_token, user], user.id == ^user_id)
    |> exclude(:select)
    |> select([token], token.id)
    |> Repo.one()
  end

  def session_token_id(_user, _token), do: nil

  @doc "The account's most recent security log entries, newest first."
  defdelegate list_security_events(user), to: SecurityLog, as: :list

  @doc "A person-readable line for a security log entry."
  defdelegate describe_security_event(event), to: SecurityLog, as: :describe

  @doc """
  Removes every second factor and recovery code from the account with
  `email`, for someone who has lost them all (RFD 19, "Recovery"). Only an
  operator runs this, through `Renga.Release.remove_mfa/2`; `actor` names
  them in the account's security log. Returns the user and whether the
  notice to the account was delivered.
  """
  def remove_mfa_by_operator(email, actor) when is_binary(email) and is_binary(actor) do
    case get_user_by_email(email) do
      nil ->
        {:error, :not_found}

      user ->
        # Under the account lock, like every factor change, so a factor
        # being added meanwhile is removed too or added after.
        remove = fn -> remove_all_mfa(user, actor) end

        with {:ok, user} <- MFA.with_account_lock(user, remove) do
          {:ok, user, SecurityLog.notify(user, "mfa_removed_by_operator")}
        end
    end
  end

  defp remove_all_mfa(user, actor) do
    MFA.remove_all(user)
    SecurityLog.record(user, "mfa_removed_by_operator", %{"actor" => actor})
    {:ok, user}
  end

  @second_step_minutes 5

  @doc """
  Records a half-finished sign-in for `user`, whose password or magic link
  passed and who still owes a second factor (RFD 19). Returns the token the
  browser keeps; only its hash is stored. It lasts five minutes, is spent by
  `finish_pending_second_step/4`, and ends early when the password or the
  account's second factors change.
  """
  def create_pending_second_step(%User{} = user) do
    token = :crypto.strong_rand_bytes(32)

    Repo.insert!(%UserToken{
      token: :crypto.hash(:sha256, token),
      context: "second_step",
      user_id: user.id
    })

    token
  end

  @doc "The user a pending sign-in `token` belongs to while it is unspent and current, or `nil`."
  def get_pending_second_step_user(token) when is_binary(token) do
    Repo.one(
      from t in UserToken,
        join: user in assoc(t, :user),
        where: t.token == ^:crypto.hash(:sha256, token) and t.context == "second_step",
        where: t.inserted_at > ago(@second_step_minutes, "minute"),
        select: user
    )
  end

  def get_pending_second_step_user(_token), do: nil

  @doc """
  Spends a pending sign-in once its second factor passed and issues the
  session for `browser_session_id`, with the recovery authorization when
  `method` is `:recovery_code`. Only one caller can spend it, so a copied
  cookie or a concurrent request cannot finish the same sign-in twice.

  It runs under the account's row lock, which a password change also takes
  when it updates the user: the change either deletes the session issued
  here or leaves no pending sign-in to finish.
  """
  def finish_pending_second_step(%User{id: user_id} = user, token, browser_session_id, method)
      when is_binary(token) do
    Repo.transact(fn ->
      Repo.one(from u in User, where: u.id == ^user_id, lock: "FOR NO KEY UPDATE", select: u.id)

      {count, _} =
        Repo.delete_all(
          from t in UserToken,
            where: t.token == ^:crypto.hash(:sha256, token) and t.context == "second_step",
            where: t.user_id == ^user_id,
            where: t.inserted_at > ago(@second_step_minutes, "minute")
        )

      if count == 1 do
        session_token = generate_user_session_token(user, browser_session_id)
        :ok = start_recovery_after(method, user, session_token)
        # Logged with the session it records, so a spent or expired
        # pending sign-in logs nothing.
        record_issued_sign_in(user, to_string(method))
        {:ok, session_token}
      else
        {:error, :expired}
      end
    end)
    |> case do
      {:ok, session_token} -> {:ok, session_token}
      {:error, _reason} -> :error
    end
  end

  defp start_recovery_after(:recovery_code, user, session_token),
    do: Recheck.start_recovery(user, session_token)

  defp start_recovery_after(_method, _user, _session_token), do: :ok

  @doc "Grants a session that signed in with a recovery code its recovery window."
  defdelegate start_recovery(user, session_token), to: Recheck

  @doc "Whether signing in as `user` needs a second step after a password or magic link."
  defdelegate mfa?(user), to: MFA

  @doc "Removes the authenticator app if this session passed the re-check."
  def remove_totp(%User{} = user, session_token) do
    if Recheck.authorized?(user, session_token, :remove_factor) do
      with {:ok, user} <- MFA.disable_totp(user) do
        SecurityLog.notify(user, "totp_removed")
        {:ok, user}
      end
    else
      {:error, :recheck_required}
    end
  end

  @doc "Replaces the recovery codes if this session passed the re-check."
  def regenerate_recovery_codes(%User{} = user, session_token) do
    if Recheck.authorized?(user, session_token, :recovery_codes) do
      with {:ok, codes} <- MFA.regenerate_recovery_codes(user) do
        SecurityLog.notify(user, "recovery_codes_generated")
        {:ok, codes}
      end
    else
      {:error, :recheck_required}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Renga.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  A session scoped to one organization changes nothing and keeps the token
  (RFD 15): its link still works after signing in another way.
  """
  def update_user_email(%User{session_organization_id: id}, _token) when not is_nil(id),
    do: {:error, :scoped_session}

  def update_user_email(user, token) do
    previous_email = user.email
    context = "change:#{previous_email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        SecurityLog.record(user, "email_changed")
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
    |> tap(fn result ->
      with {:ok, user} <- result,
           do: SecurityLog.notify(user, "email_changed", previous_email: previous_email)
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Renga.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens(&SecurityLog.record(&1, "password_changed"))
    |> tap(fn result ->
      with {:ok, {user, _tokens}} <- result, do: SecurityLog.notify(user, "password_changed")
    end)
  end

  @doc "A changeset for the person's appearance preferences, for forms."
  def change_user_appearance(%User{} = user, attrs \\ %{}),
    do: User.appearance_changeset(user, attrs)

  @doc """
  Saves the person's theme, accent, and density. They follow the person
  across devices; a blank accent follows the organization's default.
  """
  def update_user_appearance(%User{} = user, attrs) do
    user
    |> User.appearance_changeset(attrs)
    |> Repo.update()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user, browser_session_id \\ nil, expires_at \\ nil) do
    {token, user_token} = UserToken.build_session_token(user, browser_session_id)
    Repo.insert!(%{user_token | expires_at: expires_at})
    token
  end

  @doc """
  Restarts the validity period of the session `token` in place.

  Renewal keeps the token, so it never leaves a second live session behind
  and keeps everything bound to it, such as an account re-check that has not
  expired yet. It creates no evidence of its own.
  """
  def extend_user_session_token(token) when is_binary(token) do
    Repo.update_all(
      from(UserToken, where: [token: ^token, context: "session"]),
      set: [inserted_at: Renga.Time.utc_now_ms()]
    )

    :ok
  end

  @doc """
  Returns the browser session id recorded on the session `token`, recording
  a new one first for a token issued before they were recorded.
  """
  def ensure_browser_session_id(token) when is_binary(token) do
    Repo.update_all(
      from(t in UserToken,
        where: t.token == ^token and t.context == "session" and is_nil(t.browser_session_id)
      ),
      set: [browser_session_id: Ecto.UUID.generate()]
    )

    Repo.one(
      from t in UserToken,
        where: t.token == ^token and t.context == "session",
        select: t.browser_session_id
    )
  end

  @doc """
  Deletes the session `token` and every other session token of the same
  browser session: `browser_session_id`, or the one recorded on `token`.

  A late response can write an earlier token back into a browser's cookie,
  so ending a browser session must not depend on the cookie holding its
  newest token. Returns the deleted tokens so their LiveViews can be
  disconnected.
  """
  def delete_browser_session_tokens(token, browser_session_id) do
    recorded =
      if token do
        Repo.all(
          from t in UserToken,
            where: t.token == ^token and t.context == "session",
            where: not is_nil(t.browser_session_id),
            select: t.browser_session_id
        )
      else
        []
      end

    browser_session_ids = Enum.uniq(Enum.reject([browser_session_id | recorded], &is_nil/1))

    query =
      from t in UserToken,
        where: t.context == "session" and t.browser_session_id in ^browser_session_ids,
        select: t.token

    query =
      if token,
        do: or_where(query, [t], t.context == "session" and t.token == ^token),
        else: query

    {_count, tokens} = Repo.delete_all(query)
    {:ok, tokens}
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  # `on_update` runs in the same transaction, so what it records commits
  # or rolls back with the change.
  defp update_user_and_delete_all_tokens(changeset, on_update \\ fn _user -> :ok end) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        on_update.(user)
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
