defmodule Renga.Accounts.Recheck do
  @moduledoc """
  The account re-check that replaces sudo mode (RFD 19, "Account re-check").

  Changing the email address or password, adding or removing a credential,
  and linking an identity provider ask for one fresh check, in place, when
  the person saves. A passing check covers every such change from the same
  browser session for five minutes and nothing else. Signing in, silent
  renewal, and session rotation never count as a re-check (RFD 15), so the
  evidence is a separate row rather than the session's `authenticated_at`.

  An account with neither a password nor a second factor re-checks by
  signing in again at a linked deployment OpenID Connect provider (RFD 15,
  "Re-authentication and step-up"). One with none of those has nothing to
  re-check with. It proves control of its current email address instead,
  and that bootstrap authorization only lets it set its first password or add
  its first factor.

  An account an organization's provider created has no email to prove. It
  first initializes one by proving control of an address it chooses, and
  that grants the same bootstrap and nothing more (RFD 15). This is the one
  thing a session from the organization's provider can do here: the emailed
  code, not the provider, proves the mailbox.
  """

  import Ecto.Query

  alias Renga.Accounts.AccountAuthorization
  alias Renga.Accounts.AccountChallenge
  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.IdentityProviderRevision
  alias Renga.Accounts.MFA
  alias Renga.Accounts.OIDC
  alias Renga.Accounts.Passkeys
  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.SecurityLog
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Accounts.UserNotifier
  alias Renga.Accounts.UserToken
  alias Renga.Repo

  @window_minutes 5
  @max_code_attempts 5
  # Unambiguous characters, so a code read off a phone screen types back in.
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTVWXYZ23456789"
  @max_initialization_codes_per_account 5
  @max_initialization_codes_per_address 3
  @code_length 10

  @typedoc "A change the re-check guards."
  @type change ::
          :change_email
          | :set_password
          | :add_factor
          | :remove_factor
          | :recovery_codes
          | :link_identity
          | :unlink_identity

  @changes [
    :change_email,
    :set_password,
    :add_factor,
    :remove_factor,
    :recovery_codes,
    :link_identity,
    :unlink_identity
  ]
  # What an account with nothing to re-check with may do after proving its
  # email: get its first credential, and nothing else.
  @bootstrap_changes [:set_password, :add_factor]

  @doc "How long a passing check or a bootstrap authorization lasts."
  def window_minutes, do: @window_minutes

  @doc """
  The ways this account can pass the re-check. An account with a second
  factor confirms with a passkey or authenticator code; one without enters
  its password; one with neither signs in again at a linked provider
  (`:provider`, see `provider_identities/1`). An empty list means the
  account must bootstrap through its email first.
  """
  def methods(%User{} = user) do
    factors =
      Enum.filter(
        [passkey: Passkeys.any?(user), totp: MFA.totp_enabled?(user)],
        fn {_method, held?} -> held? end
      )

    cond do
      factors != [] -> Keyword.keys(factors)
      user.hashed_password -> [:password]
      provider_identities(user) != [] -> [:provider]
      true -> []
    end
  end

  @doc """
  The account's identities that can pass the re-check: OpenID Connect
  identities at usable deployment providers. GitHub OAuth cannot show a
  fresh authentication, and an organization's provider never authorizes an
  account-wide change.
  """
  def provider_identities(%User{id: user_id}) do
    UserIdentity
    |> join(:inner, [identity], provider in assoc(identity, :provider))
    |> where([identity, provider], identity.user_id == ^user_id)
    |> where([_identity, provider], provider.kind == "oidc" and is_nil(provider.organization_id))
    |> where([_identity, provider], is_nil(provider.removed_at) and provider.enabled)
    |> where([_identity, provider], not is_nil(provider.active_revision))
    |> order_by([_identity, provider], asc: provider.display_name)
    |> preload([_identity, provider], provider: provider)
    |> Repo.all()
  end

  @doc """
  Whether `user` may make `change` from the browser session holding
  `session_token` without being asked again.
  """
  def authorized?(%User{} = user, session_token, change) when change in @changes do
    case fetch_session(user, session_token, :any_scope) do
      # A scoped session gets a bootstrap only by initializing the email.
      {:ok, %UserToken{scoped_organization_id: nil} = session} ->
        active?(session, "recheck") or bootstrapped?(user, session, change) or
          (change == :add_factor and active?(session, "recovery"))

      {:ok, session} ->
        bootstrapped?(user, session, change)

      :error ->
        false
    end
  end

  def authorized?(_user, _session_token, _change), do: false

  defp bootstrapped?(user, session, change) do
    change in @bootstrap_changes and methods(user) == [] and active?(session, "bootstrap")
  end

  @doc """
  Whether this session is recovering an account after spending a recovery
  code, and may still add its one replacement factor.
  """
  def recovering?(%User{} = user, session_token) do
    case fetch_session(user, session_token) do
      {:ok, session} -> active?(session, "recovery")
      :error -> false
    end
  end

  @doc """
  Starts the five-minute recovery authorization for a session that signed
  in with a recovery code (RFD 19, "Recovery"). It allows adding one
  replacement factor and nothing else.
  """
  def start_recovery(%User{} = user, session_token) do
    case fetch_session(user, session_token) do
      {:ok, session} -> grant(session, "recovery")
      :error -> {:error, :no_session}
    end
  end

  @doc """
  Spends this session's recovery authorization, if it is still active.
  Called inside the transaction that adds the replacement factor, so only
  one replacement can use it and a failed one leaves it in place.
  """
  def spend_recovery(%User{} = user, session_token) do
    case fetch_session(user, session_token) do
      {:ok, session} ->
        now = Renga.Time.utc_now_ms()

        {count, _} =
          AccountAuthorization
          |> where(session_token_id: ^session.id, purpose: "recovery")
          |> where([authorization], authorization.expires_at > ^now)
          |> Repo.delete_all()

        count == 1

      :error ->
        false
    end
  end

  @doc """
  Checks `password` and, if it is the account's password, records a re-check
  for this session.
  """
  def recheck_with_password(%User{} = user, session_token, password) when is_binary(password) do
    with {:ok, session} <- fetch_session(user, session_token),
         true <- :password in methods(user) || {:error, :not_available},
         true <- User.valid_password?(user, password) || {:error, :invalid_password} do
      grant(session, "recheck")
    else
      :error -> {:error, :no_session}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Checks an authenticator code and, if it is good, records a re-check for
  this session.
  """
  def recheck_with_totp(%User{} = user, session_token, code) when is_binary(code) do
    with {:ok, session} <- fetch_session(user, session_token),
         :ok <- MFA.verify_totp(user, code) do
      grant(session, "recheck")
    else
      :error -> {:error, :no_session}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Verifies a passkey assertion from `user` and, if it passes, records a
  re-check for this session.
  """
  def recheck_with_passkey(%User{} = user, session_token, response) when is_map(response) do
    with {:ok, session} <- fetch_session(user, session_token),
         {:ok, _user, _passkey} <- Passkeys.authenticate("recheck", response, user) do
      grant(session, "recheck")
    else
      :error -> {:error, :no_session}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Records a re-check for this session from a provider sign-in that
  `OIDC.finish/4` validated for a re-check attempt bound to this session.
  It counts only for an account whose re-check method is `:provider`, when
  the token's subject is `identity_id`'s at the same provider, so switching
  accounts at the provider fails, and when `auth_time` shows the person
  authenticated within the re-check window.

  The grant is recorded under a share lock on the provider, and only while
  it still uses the revision the token was validated with: an operator who
  replaced, disabled, or removed the provider while the browser was there
  leaves nothing to grant.
  """
  def recheck_with_provider(%User{} = user, session_token, identity_id, %{
        provider: provider,
        revision: %IdentityProviderRevision{number: number},
        claims: claims
      }) do
    Repo.transact(fn ->
      with {:ok, session} <- fetch_session(user, session_token),
           :ok <- lock_current_provider(provider, number),
           true <- methods(user) == [:provider] || {:error, :not_available},
           %UserIdentity{} = identity <-
             Enum.find(provider_identities(user), &(&1.id == identity_id)) ||
               {:error, :not_available},
           true <-
             (identity.provider_id == provider.id and claims["sub"] == identity.subject) ||
               {:error, :wrong_account},
           true <- OIDC.fresh_authentication?(claims) || {:error, :stale_authentication} do
        {:ok, grant(session, "recheck")}
      else
        :error -> {:error, :no_session}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  def recheck_with_provider(_user, _session_token, _identity_id, _result),
    do: {:error, :not_available}

  defp lock_current_provider(%IdentityProvider{id: id}, number) do
    Repo.one(
      from p in IdentityProvider,
        where: p.id == ^id and is_nil(p.organization_id) and is_nil(p.removed_at),
        lock: "FOR SHARE"
    )
    |> case do
      %{enabled: true, active_revision: ^number} -> :ok
      %{enabled: true} -> {:error, :provider_changed}
      _disabled_or_removed -> {:error, :not_available}
    end
  end

  @doc """
  Emails a bootstrap code to the account's current address, replacing any
  code this session asked for earlier. Only an account with no re-check
  method can bootstrap.
  """
  def deliver_bootstrap_code(%User{} = user, session_token) do
    with [] <- methods(user),
         {:ok, session} <- fetch_session(user, session_token) do
      code = generate_code()

      Repo.insert!(
        %AccountChallenge{
          user_id: user.id,
          session_token_id: session.id,
          purpose: "bootstrap",
          code_hash: hash_code(code),
          sent_to: user.email,
          expires_at: expires_at()
        },
        on_conflict: {:replace, [:code_hash, :sent_to, :attempts, :expires_at, :inserted_at]},
        conflict_target: [:session_token_id, :purpose]
      )

      UserNotifier.deliver_bootstrap_code(user, format_code(code))
    else
      :error -> {:error, :no_session}
      [_ | _] -> {:error, :not_available}
    end
  end

  @doc """
  Grants the bootstrap authorization to a session that just signed in by
  proving control of the email for this purpose, such as confirming a new
  account to add a passkey. Only an account with no re-check method can
  bootstrap.
  """
  def start_bootstrap(%User{} = user, session_token) do
    with [] <- methods(user),
         {:ok, session} <- fetch_session(user, session_token) do
      grant(session, "bootstrap")
    else
      :error -> {:error, :no_session}
      [_ | _] -> {:error, :not_available}
    end
  end

  @doc """
  Spends a bootstrap code. A correct code grants this session the bootstrap
  authorization; each wrong one counts against the challenge.
  """
  def verify_bootstrap_code(%User{} = user, session_token, code) when is_binary(code) do
    with [] <- methods(user),
         {:ok, session} <- fetch_session(user, session_token) do
      # Commit even when the code is wrong, so the attempt counts.
      {:ok, result} = Repo.transaction(fn -> spend_code(user, session, normalize_code(code)) end)
      result
    else
      :error -> {:error, :no_session}
      [_ | _] -> {:error, :not_available}
    end
  end

  @doc """
  Emails a code to `email` so an account with no email and nothing to
  re-check with, such as one an organization's provider created, can make
  it the account's login email. Replaces any code this session asked for
  earlier. Returns `{:error, changeset}` for a malformed address.

  An address that belongs to another account gets a code like any other,
  and is refused only once that code proves the mailbox
  (`verify_email_initialization_code/3`): refusing it here would let anyone
  holding such an account learn which addresses have Renga accounts.

  Each account may send `#{@max_initialization_codes_per_account}` codes an
  hour, and each address receive `#{@max_initialization_codes_per_address}`,
  whatever session or account asks: `{:error, :rate_limited}` past that.
  The limit on each challenge's wrong attempts stops guessing; this one
  stops the account from using Renga to mail arbitrary addresses.
  """
  def deliver_email_initialization_code(%User{} = user, session_token, email)
      when is_binary(email) do
    with {:ok, session} <- fetch_session(user, session_token, :any_scope),
         %User{email: nil} = current <- Repo.get(User, user.id),
         [] <- methods(current),
         {:ok, %User{email: email}} <-
           current
           |> User.email_changeset(%{email: email}, validate_unique: false)
           |> Ecto.Changeset.apply_action(:insert),
         {:ok, code} <- issue_initialization_code(current, session, email) do
      UserNotifier.deliver_email_initialization_code(email, format_code(code))
    else
      :error -> {:error, :no_session}
      {:error, %Ecto.Changeset{}} = error -> error
      {:error, :rate_limited} = error -> error
      _has_email_or_methods -> {:error, :not_available}
    end
  end

  # Counts and records the send under the account's row lock and a lock on
  # the address, so concurrent requests, from one account or from several,
  # can't each slip under a limit.
  defp issue_initialization_code(user, session, email) do
    Repo.transact(fn ->
      Repo.one!(from u in User, where: u.id == ^user.id, select: u.id, lock: "FOR UPDATE")

      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtext('renga.email_initialization'), hashtext($1))",
        [String.downcase(email)]
      )

      if initialization_codes_exhausted?(user, email) do
        {:error, :rate_limited}
      else
        code = generate_code()

        Repo.insert!(
          %AccountChallenge{
            user_id: user.id,
            session_token_id: session.id,
            purpose: "email_initialization",
            code_hash: hash_code(code),
            sent_to: email,
            expires_at: expires_at()
          },
          on_conflict: {:replace, [:code_hash, :sent_to, :attempts, :expires_at, :inserted_at]},
          conflict_target: [:session_token_id, :purpose]
        )

        SecurityLog.record(user, "email_initialization_code_sent", %{
          "sent_to" => String.downcase(email)
        })

        {:ok, code}
      end
    end)
  end

  defp initialization_codes_exhausted?(user, email) do
    since = DateTime.add(Renga.Time.utc_now_ms(), -1, :hour)

    sent =
      SecurityEvent
      |> where(kind: "email_initialization_code_sent")
      |> where([event], event.inserted_at > ^since)

    Repo.aggregate(where(sent, user_id: ^user.id), :count) >=
      @max_initialization_codes_per_account or
      Repo.aggregate(
        where(
          sent,
          [event],
          fragment("?->>'sent_to'", event.metadata) == ^String.downcase(email)
        ),
        :count
      ) >= @max_initialization_codes_per_address
  end

  @doc """
  Spends an email initialization code. A correct one makes the address the
  account's confirmed login email and grants this session the bootstrap,
  but only while the account still has no email and nothing to re-check
  with. Each wrong code counts against the challenge.
  """
  def verify_email_initialization_code(%User{} = user, session_token, code)
      when is_binary(code) do
    case fetch_session(user, session_token, :any_scope) do
      {:ok, session} -> spend_initialization_code(user, session, normalize_code(code))
      :error -> {:error, :no_session}
    end
  end

  # Commits even when the code is wrong, so the attempt counts.
  defp spend_initialization_code(user, session, code) do
    case Repo.transaction(fn -> initialize_email(user, session, code) end) do
      {:ok, result} -> result
      {:error, :email_in_use} -> {:error, :email_in_use}
    end
  end

  defp initialize_email(user, session, code) do
    # Conflicts with the lock adding a factor takes, so the account can't
    # gain a credential between the check and the grant.
    current = Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
    current = %{current | session_organization_id: user.session_organization_id}

    challenge =
      AccountChallenge
      |> where(session_token_id: ^session.id, purpose: "email_initialization")
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      current.email || methods(current) != [] ->
        {:error, :not_available}

      is_nil(challenge) or expired?(challenge.expires_at) ->
        {:error, :expired}

      challenge.attempts >= @max_code_attempts ->
        {:error, :too_many_attempts}

      Plug.Crypto.secure_compare(challenge.code_hash, hash_code(code)) ->
        Repo.delete!(challenge)
        put_initialized_email(current, session, challenge.sent_to)

      true ->
        Repo.update_all(where(AccountChallenge, id: ^challenge.id), inc: [attempts: 1])
        {:error, :invalid_code}
    end
  end

  defp put_initialized_email(user, session, email) do
    user
    |> User.email_changeset(%{email: email})
    |> Ecto.Changeset.put_change(:confirmed_at, Renga.Time.utc_now_ms())
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        SecurityLog.record(updated, "email_initialized")
        :ok = grant(session, "bootstrap")
        {:ok, updated}

      # Someone registered the address after the code went out.
      {:error, _changeset} ->
        Repo.rollback(:email_in_use)
    end
  end

  defp spend_code(user, session, code) do
    challenge =
      AccountChallenge
      |> where(session_token_id: ^session.id, purpose: "bootstrap")
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      is_nil(challenge) or expired?(challenge.expires_at) or challenge.sent_to != user.email ->
        {:error, :expired}

      challenge.attempts >= @max_code_attempts ->
        {:error, :too_many_attempts}

      Plug.Crypto.secure_compare(challenge.code_hash, hash_code(code)) ->
        Repo.delete!(challenge)
        grant(session, "bootstrap")

      true ->
        Repo.update_all(where(AccountChallenge, id: ^challenge.id), inc: [attempts: 1])
        {:error, :invalid_code}
    end
  end

  defp grant(%UserToken{} = session, purpose) do
    Repo.insert!(
      %AccountAuthorization{
        user_id: session.user_id,
        session_token_id: session.id,
        purpose: purpose,
        expires_at: expires_at()
      },
      on_conflict: {:replace, [:expires_at, :inserted_at]},
      conflict_target: [:session_token_id, :purpose]
    )

    :ok
  end

  defp active?(%UserToken{id: session_id}, purpose) do
    now = Renga.Time.utc_now_ms()

    AccountAuthorization
    |> where(session_token_id: ^session_id, purpose: ^purpose)
    |> where([authorization], authorization.expires_at > ^now)
    |> Repo.exists?()
  end

  # The session must still be a valid session of this user; a token that was
  # expired or belongs to someone else authorizes nothing. Nor does a session
  # from an organization provider's sign-in: that organization's owners
  # control the identity it proved, so it never reaches an account-wide
  # credential (RFD 15).
  # Only email initialization and what its bootstrap allows pass
  # `:any_scope`.
  defp fetch_session(user, session_token, scope \\ :unscoped)

  defp fetch_session(%User{id: user_id}, session_token, scope) when is_binary(session_token) do
    {:ok, query} = UserToken.verify_session_token_query(session_token)

    case query |> exclude(:select) |> select([token], token) |> Repo.one() do
      %UserToken{user_id: ^user_id, scoped_organization_id: nil} = token -> {:ok, token}
      %UserToken{user_id: ^user_id} = token when scope == :any_scope -> {:ok, token}
      _ -> :error
    end
  end

  defp fetch_session(_user, _session_token, _scope), do: :error

  defp expires_at, do: DateTime.add(Renga.Time.utc_now_ms(), @window_minutes, :minute)

  defp expired?(expires_at), do: DateTime.compare(expires_at, Renga.Time.utc_now_ms()) != :gt

  # Rejection sampling keeps every character equally likely.
  defp generate_code(acc \\ "")

  defp generate_code(acc) when byte_size(acc) == @code_length, do: acc

  defp generate_code(acc) do
    <<byte>> = :crypto.strong_rand_bytes(1)
    alphabet_size = length(@code_alphabet)

    if byte < 256 - rem(256, alphabet_size) do
      generate_code(acc <> <<Enum.at(@code_alphabet, rem(byte, alphabet_size))>>)
    else
      generate_code(acc)
    end
  end

  defp format_code(code), do: String.slice(code, 0, 5) <> "-" <> String.slice(code, 5, 5)

  defp normalize_code(code), do: code |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")

  defp hash_code(code), do: :crypto.hash(:sha256, code)
end
