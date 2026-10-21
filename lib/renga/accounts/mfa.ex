defmodule Renga.Accounts.MFA do
  @moduledoc """
  Second factors and recovery codes (RFD 19, "Credentials").

  An account has multi-factor authentication when it holds an authenticator
  app or a passkey (`Renga.Accounts.Passkeys`). Adding the first factor generates
  ten recovery codes; removing the last one discards them, since a recovery
  code only ever stands in for a second factor.

  Authenticator codes are rate limited per account and never accepted twice:
  the last accepted 30-second step is stored, and only a later step passes.
  Every failure is recorded in the account's security log.

  Every check and change of an account's second factors and recovery codes
  runs under a lock on the account's row, so concurrent requests see each
  other's failures, spent steps, and replaced code sets.

  Authenticator secrets are encrypted with `Renga.Vault` and bound to their
  account, so a database dump alone cannot produce codes. A secret sealed by
  an older key is resealed with the current one when it is next used, and
  `reencrypt_totp_secrets/0` reseals the rest before an old key is retired.

  Callers check the account re-check (`Renga.Accounts.Recheck`) before
  changing a credential; this module only enforces the credential rules.
  """

  import Ecto.Query

  alias Renga.Accounts.Passkeys
  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.User
  alias Renga.Accounts.UserRecoveryCode
  alias Renga.Accounts.UserTOTP
  alias Renga.Repo
  alias Renga.Vault

  require Logger

  @period 30
  # Accept the neighbouring steps too, for clocks that drift.
  @drift_steps 1
  @recovery_code_count 10
  @max_failures 10
  @failure_window_minutes 15

  @doc "Whether the account holds a second factor: a passkey or an authenticator app."
  def mfa?(%User{} = user), do: totp_enabled?(user) or Passkeys.any?(user)

  @doc "Discards the recovery codes once the account has no second factor left."
  def discard_recovery_codes_without_mfa(%User{} = user) do
    unless mfa?(user), do: Repo.delete_all(where(UserRecoveryCode, user_id: ^user.id))
    :ok
  end

  @doc """
  Adds a second factor with `insert`, under the account lock, once
  `authorize` agrees there. Returns `{:ok, {factor, codes}}`, with new
  recovery codes when it is the account's first factor. Anything `insert`
  spent, such as a passkey challenge, is kept only if the factor is saved.
  """
  def add_factor(%User{} = user, insert, authorize) do
    with_account_lock(user, fn ->
      first_factor? = not mfa?(user)

      if authorize.() do
        with {:ok, factor} <- insert.() do
          end_pending_sign_ins(user)
          {:ok, {factor, if(first_factor?, do: replace_recovery_codes(user))}}
        end
      else
        {:error, :recheck_required}
      end
    end)
  end

  @doc """
  Removes a second factor with `delete`, under the account lock, once
  `authorize` agrees there, and discards the recovery codes with the last
  factor.
  """
  def remove_factor(%User{} = user, delete, authorize) do
    with_account_lock(user, fn ->
      if authorize.() do
        with {:ok, factor} <- delete.() do
          discard_recovery_codes_without_mfa(user)
          end_pending_sign_ins(user)
          {:ok, factor}
        end
      else
        {:error, :recheck_required}
      end
    end)
  end

  @doc "Whether the account has an authenticator app."
  def totp_enabled?(%User{id: user_id}), do: Repo.exists?(where(UserTOTP, user_id: ^user_id))

  @doc "A new random authenticator secret, not yet saved."
  def new_totp_secret, do: NimbleTOTP.secret()

  @doc "Whether authenticator secrets can be stored: `Renga.Vault` has a key."
  def totp_available?, do: not is_nil(Vault.current_key_id())

  @doc "The `otpauth://` URI an authenticator app scans to add `secret`."
  def totp_uri(%User{email: email}, secret) do
    NimbleTOTP.otpauth_uri("Renga:#{email}", secret, issuer: "Renga")
  end

  @doc "The secret in the base32 form people type into an app by hand."
  def format_totp_secret(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @doc """
  Saves `secret` as the account's authenticator app once `code` proves the
  app produces it. Returns the new recovery codes when this is the account's
  first factor, otherwise `nil`.

  With `replace: true` the new app takes the place of an existing one, for
  recovery when the old app is lost. A replacement keeps the remaining
  recovery codes and returns none: new codes need the ordinary re-check.

  `authorize`, if given, runs under the account lock once the code is proved
  and must return true for the app to be saved; a recovery grant is spent
  there, so it is spent exactly when the replacement is saved.
  """
  def enable_totp(%User{} = user, secret, code, opts \\ [])
      when is_binary(secret) and is_binary(code) do
    with_account_lock(user, fn -> enable_totp_locked(user, secret, code, opts) end)
  end

  defp enable_totp_locked(user, secret, code, opts) do
    replace? = Keyword.get(opts, :replace, false)
    authorize = Keyword.get(opts, :authorize, fn -> true end)

    if totp_enabled?(user) and not replace? do
      {:error, :already_enabled}
    else
      case matching_step(secret, code, nil) do
        nil ->
          record_event(user, "totp_enable_failed")
          {:ok, {:error, :invalid_code}}

        step ->
          # Checked under the lock, once the code proved the app.
          insert_authorized_totp(authorize.(), user, secret, step, replace?)
      end
    end
  end

  defp insert_authorized_totp(authorized?, user, secret, step, replace?) do
    if authorized?,
      do: insert_totp(user, secret, step, replace?),
      else: {:error, :recheck_required}
  end

  defp insert_totp(user, secret, step, replace?) do
    first_factor? = not replace? and not mfa?(user)
    if replace?, do: Repo.delete_all(where(UserTOTP, user_id: ^user.id))
    end_pending_sign_ins(user)

    case Vault.encrypt(secret, secret_aad(user.id)) do
      {:ok, key_id, ciphertext} ->
        Repo.insert!(%UserTOTP{
          user_id: user.id,
          secret_ciphertext: ciphertext,
          secret_key_id: key_id,
          last_used_step: step
        })

        record_event(user, "totp_added")
        {:ok, if(first_factor?, do: replace_recovery_codes(user))}

      {:error, :no_key} ->
        {:error, :no_encryption_key}
    end
  end

  @doc "Removes the authenticator app, and the recovery codes with the last factor."
  def disable_totp(%User{} = user) do
    with_account_lock(user, fn ->
      Repo.delete_all(where(UserTOTP, user_id: ^user.id))
      discard_recovery_codes_without_mfa(user)
      end_pending_sign_ins(user)
      record_event(user, "totp_removed")
      {:ok, user}
    end)
  end

  @doc """
  Checks an authenticator code and, if it is good, spends its time step.

  A secret that cannot be decrypted, because its key is gone or the row was
  tampered with, accepts nothing.
  """
  def verify_totp(%User{} = user, code) when is_binary(code) do
    with_account_lock(user, fn ->
      totp = Repo.one(where(UserTOTP, user_id: ^user.id))

      cond do
        is_nil(totp) ->
          {:error, :not_enabled}

        rate_limited?(user) ->
          record_event(user, "second_factor_rate_limited", %{"method" => "totp"})
          {:ok, {:error, :rate_limited}}

        true ->
          check_totp(user, totp, code)
      end
    end)
  end

  defp check_totp(user, totp, code) do
    case decrypt_secret(totp) do
      {:ok, secret} ->
        if step = matching_step(secret, code, totp.last_used_step) do
          Repo.update_all(where(UserTOTP, id: ^totp.id),
            set: [last_used_step: step] ++ resealed(user, totp, secret)
          )

          :ok
        else
          record_event(user, "totp_failed")
          {:ok, {:error, :invalid_code}}
        end

      {:error, reason} ->
        Logger.error("Authenticator secret for user #{user.id} cannot be decrypted: #{reason}")
        {:error, :unavailable}
    end
  end

  # Moves a secret sealed by an older key to the current one while it is
  # decrypted anyway.
  defp resealed(user, totp, secret) do
    with current when not is_nil(current) and current != totp.secret_key_id <-
           Vault.current_key_id(),
         {:ok, key_id, ciphertext} <- Vault.encrypt(secret, secret_aad(user.id)) do
      [secret_ciphertext: ciphertext, secret_key_id: key_id]
    else
      _ -> []
    end
  end

  @doc """
  Reseals every authenticator secret not yet under the current key, so the
  operator can then retire the old one. Returns how many were resealed, or
  the first secret that could not be decrypted.
  """
  def reencrypt_totp_secrets do
    current = Vault.current_key_id()

    if is_nil(current) do
      {:error, :no_key}
    else
      UserTOTP
      |> where([totp], totp.secret_key_id != ^current)
      |> Repo.all()
      |> Enum.reduce_while({:ok, 0}, &reencrypt_next/2)
    end
  end

  defp reencrypt_next(totp, {:ok, count}) do
    case reencrypt_totp(totp.user_id) do
      {:ok, :resealed} -> {:cont, {:ok, count + 1}}
      {:ok, :current} -> {:cont, {:ok, count}}
      {:error, reason} -> {:halt, {:error, {totp.user_id, reason}}}
    end
  end

  defp reencrypt_totp(user_id) do
    with_account_lock(%User{id: user_id}, fn -> reencrypt_totp_locked(user_id) end)
  end

  defp reencrypt_totp_locked(user_id) do
    with %UserTOTP{} = totp <- Repo.one(where(UserTOTP, user_id: ^user_id)),
         {:ok, secret} <- decrypt_secret(totp) do
      # A sign-in may have resealed it since it was listed.
      case resealed(%User{id: user_id}, totp, secret) do
        [] ->
          {:ok, :current}

        changes ->
          Repo.update_all(where(UserTOTP, id: ^totp.id), set: changes)
          {:ok, :resealed}
      end
    else
      nil -> {:ok, :current}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Replaces the account's recovery codes with a fresh set and returns the
  codes, which are never shown again. Only an account with MFA has codes.
  """
  def regenerate_recovery_codes(%User{} = user) do
    with_account_lock(user, fn ->
      if mfa?(user) do
        codes = replace_recovery_codes(user)
        record_event(user, "recovery_codes_generated")
        {:ok, codes}
      else
        {:error, :no_mfa}
      end
    end)
  end

  @doc "How many unused recovery codes the account has left."
  def recovery_codes_left(%User{id: user_id}) do
    UserRecoveryCode
    |> where(user_id: ^user_id)
    |> where([code], is_nil(code.used_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Spends one recovery code. Used as the second step when every factor is
  lost; recovery codes are rate limited with authenticator codes.
  """
  def spend_recovery_code(%User{} = user, code) when is_binary(code) do
    with_account_lock(user, fn -> spend_recovery_code_locked(user, code) end)
  end

  defp spend_recovery_code_locked(user, code) do
    if rate_limited?(user) do
      record_event(user, "second_factor_rate_limited", %{"method" => "recovery_code"})
      {:ok, {:error, :rate_limited}}
    else
      {count, _} =
        UserRecoveryCode
        |> where(user_id: ^user.id, code_hash: ^hash_recovery_code(code))
        |> where([code], is_nil(code.used_at))
        |> Repo.update_all(set: [used_at: Renga.Time.utc_now_ms()])

      if count == 1 do
        record_event(user, "recovery_code_used")
        :ok
      else
        record_event(user, "recovery_code_failed")
        {:ok, {:error, :invalid_code}}
      end
    end
  end

  # Runs `fun` in a transaction holding the account's row lock, which every
  # second-factor check and change takes first. `fun` returns `{:ok, error}`
  # to commit what it recorded, such as a failure, and still report `error`.
  defp with_account_lock(%User{id: user_id}, fun) do
    Repo.transact(fn ->
      User
      |> where(id: ^user_id)
      |> lock("FOR NO KEY UPDATE")
      |> select([user], user.id)
      |> Repo.one()

      case fun.() do
        :ok -> {:ok, :ok}
        {:ok, _value} = ok -> ok
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, {:error, _reason} = error} -> error
      other -> other
    end
  end

  # A sign-in that started before the account's factors changed must start
  # again against the factors it has now.
  defp end_pending_sign_ins(user) do
    Repo.delete_all(
      from token in Renga.Accounts.UserToken,
        where: token.user_id == ^user.id and token.context == "second_step"
    )
  end

  defp secret_aad(user_id), do: "renga:user_totp:" <> user_id

  defp decrypt_secret(%UserTOTP{} = totp) do
    Vault.decrypt(totp.secret_key_id, totp.secret_ciphertext, secret_aad(totp.user_id))
  end

  defp replace_recovery_codes(user) do
    Repo.delete_all(where(UserRecoveryCode, user_id: ^user.id))
    now = Renga.Time.utc_now_ms()
    codes = for _ <- 1..@recovery_code_count, do: generate_recovery_code()

    Repo.insert_all(
      UserRecoveryCode,
      Enum.map(codes, fn code ->
        %{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          code_hash: hash_recovery_code(code),
          inserted_at: now
        }
      end)
    )

    codes
  end

  # The step `code` belongs to, if it matches a step around now that is newer
  # than the last one accepted.
  defp matching_step(secret, code, last_used_step) do
    code = String.replace(code, ~r/\s/, "")
    current = div(System.os_time(:second), @period)

    # Newest first: if two neighbouring steps share digits, a code spends
    # the later one, so it cannot be accepted again for the earlier.
    Enum.find((current + @drift_steps)..(current - @drift_steps)//-1, fn step ->
      (is_nil(last_used_step) or step > last_used_step) and
        Plug.Crypto.secure_compare(
          NimbleTOTP.verification_code(secret, time: step * @period),
          code
        )
    end)
  end

  defp rate_limited?(user) do
    since = DateTime.add(Renga.Time.utc_now_ms(), -@failure_window_minutes, :minute)

    SecurityEvent
    |> where(user_id: ^user.id)
    |> where([event], event.kind in ["totp_failed", "recovery_code_failed"])
    |> where([event], event.inserted_at > ^since)
    |> Repo.aggregate(:count)
    |> Kernel.>=(@max_failures)
  end

  defp record_event(user, kind, metadata \\ %{}) do
    Repo.insert!(%SecurityEvent{user_id: user.id, kind: kind, metadata: metadata})
  end

  # Sixteen base32 characters, about 80 bits, in groups people can copy.
  defp generate_recovery_code do
    :crypto.strong_rand_bytes(10)
    |> Base.encode32(case: :lower, padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp hash_recovery_code(code) do
    normalized = code |> String.downcase() |> String.replace(~r/[^a-z2-7]/, "")
    :crypto.hash(:sha256, normalized)
  end
end
