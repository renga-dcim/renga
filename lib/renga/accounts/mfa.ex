defmodule Renga.Accounts.MFA do
  @moduledoc """
  Second factors and recovery codes (RFD 19, "Credentials").

  An account has multi-factor authentication when it holds an authenticator
  app (and, once they land, a passkey). Adding the first factor generates
  ten recovery codes; removing the last one discards them, since a recovery
  code only ever stands in for a second factor.

  Authenticator codes are rate limited per account and never accepted twice:
  the last accepted 30-second step is stored, and only a later step passes.
  Every failure is recorded in the account's security log.

  Callers check the account re-check (`Renga.Accounts.Recheck`) before
  changing a credential; this module only enforces the credential rules.
  """

  import Ecto.Query

  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.User
  alias Renga.Accounts.UserRecoveryCode
  alias Renga.Accounts.UserTOTP
  alias Renga.Repo

  @period 30
  # Accept the neighbouring steps too, for clocks that drift.
  @drift_steps 1
  @recovery_code_count 10
  @max_failures 10
  @failure_window_minutes 15

  @doc "Whether the account holds a second factor."
  def mfa?(%User{} = user), do: totp_enabled?(user)

  @doc "Whether the account has an authenticator app."
  def totp_enabled?(%User{id: user_id}), do: Repo.exists?(where(UserTOTP, user_id: ^user_id))

  @doc "A new random authenticator secret, not yet saved."
  def new_totp_secret, do: NimbleTOTP.secret()

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
  """
  def enable_totp(%User{} = user, secret, code) when is_binary(secret) and is_binary(code) do
    case matching_step(secret, code, nil) do
      nil ->
        record_event(user, "totp_enable_failed")
        {:error, :invalid_code}

      step ->
        Repo.transact(fn -> insert_totp(user, secret, step) end)
    end
  end

  defp insert_totp(user, secret, step) do
    first_factor? = not mfa?(user)

    %UserTOTP{user_id: user.id, secret: secret, last_used_step: step}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:user_id)
    |> Repo.insert()
    |> case do
      {:ok, _totp} ->
        record_event(user, "totp_added")
        {:ok, if(first_factor?, do: replace_recovery_codes(user))}

      {:error, _changeset} ->
        {:error, :already_enabled}
    end
  end

  @doc "Removes the authenticator app, and the recovery codes with the last factor."
  def disable_totp(%User{} = user) do
    Repo.transact(fn ->
      Repo.delete_all(where(UserTOTP, user_id: ^user.id))
      unless mfa?(user), do: Repo.delete_all(where(UserRecoveryCode, user_id: ^user.id))
      record_event(user, "totp_removed")
      {:ok, user}
    end)
  end

  @doc """
  Checks an authenticator code and, if it is good, spends its time step.
  """
  def verify_totp(%User{} = user, code) when is_binary(code) do
    Repo.transact(fn ->
      totp =
        UserTOTP
        |> where(user_id: ^user.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(totp) ->
          {:error, :not_enabled}

        rate_limited?(user) ->
          {:error, :rate_limited}

        step = matching_step(totp.secret, code, totp.last_used_step) ->
          Repo.update_all(where(UserTOTP, id: ^totp.id), set: [last_used_step: step])
          {:ok, step}

        true ->
          {:ok, :invalid}
      end
    end)
    |> case do
      {:ok, :invalid} ->
        # Recorded outside the locked transaction's result so it always
        # counts towards the limit.
        record_event(user, "totp_failed")
        {:error, :invalid_code}

      {:ok, _step} ->
        :ok

      error ->
        error
    end
  end

  @doc """
  Replaces the account's recovery codes with a fresh set and returns the
  codes, which are never shown again. Only an account with MFA has codes.
  """
  def regenerate_recovery_codes(%User{} = user) do
    if mfa?(user) do
      Repo.transact(fn ->
        codes = replace_recovery_codes(user)
        record_event(user, "recovery_codes_generated")
        {:ok, codes}
      end)
    else
      {:error, :no_mfa}
    end
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
    if rate_limited?(user) do
      {:error, :rate_limited}
    else
      now = Renga.Time.utc_now_ms()

      {count, _} =
        UserRecoveryCode
        |> where(user_id: ^user.id, code_hash: ^hash_recovery_code(code))
        |> where([code], is_nil(code.used_at))
        |> Repo.update_all(set: [used_at: now])

      if count == 1 do
        record_event(user, "recovery_code_used")
        :ok
      else
        record_event(user, "recovery_code_failed")
        {:error, :invalid_code}
      end
    end
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

    Enum.find((current - @drift_steps)..(current + @drift_steps), fn step ->
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
