defmodule Renga.Accounts.Recheck do
  @moduledoc """
  The account re-check that replaces sudo mode (RFD 19, "Account re-check").

  Changing the email address or password, adding or removing a credential,
  and linking an identity provider ask for one fresh check, in place, when
  the person saves. A passing check covers every such change from the same
  browser session for five minutes and nothing else. Signing in, silent
  renewal, and session rotation never count as a re-check (RFD 15), so the
  evidence is a separate row rather than the session's `authenticated_at`.

  An account with neither a password nor a second factor has nothing to
  re-check with. It proves control of its current email address instead,
  and that bootstrap authorization only lets it set its first password or add
  its first factor.
  """

  import Ecto.Query

  alias Renga.Accounts.AccountAuthorization
  alias Renga.Accounts.AccountChallenge
  alias Renga.Accounts.MFA
  alias Renga.Accounts.User
  alias Renga.Accounts.UserNotifier
  alias Renga.Accounts.UserToken
  alias Renga.Repo

  @window_minutes 5
  @max_code_attempts 5
  # Unambiguous characters, so a code read off a phone screen types back in.
  @code_alphabet ~c"ABCDEFGHJKMNPQRSTVWXYZ23456789"
  @code_length 10

  @typedoc "A change the re-check guards."
  @type change :: :change_email | :set_password | :add_factor | :remove_factor | :recovery_codes

  @changes [:change_email, :set_password, :add_factor, :remove_factor, :recovery_codes]
  # What an account with nothing to re-check with may do after proving its
  # email: get its first credential, and nothing else.
  @bootstrap_changes [:set_password, :add_factor]

  @doc "How long a passing check or a bootstrap authorization lasts."
  def window_minutes, do: @window_minutes

  @doc """
  The ways this account can pass the re-check. An account with a second
  factor confirms with it; one without enters its password. An empty list
  means the account must bootstrap through its email first.
  """
  def methods(%User{} = user) do
    cond do
      MFA.totp_enabled?(user) -> [:totp]
      user.hashed_password -> [:password]
      true -> []
    end
  end

  @doc """
  Whether `user` may make `change` from the browser session holding
  `session_token` without being asked again.
  """
  def authorized?(%User{} = user, session_token, change) when change in @changes do
    case fetch_session(user, session_token) do
      {:ok, session} ->
        active?(session, "recheck") or
          (change in @bootstrap_changes and methods(user) == [] and
             active?(session, "bootstrap"))

      :error ->
        false
    end
  end

  def authorized?(_user, _session_token, _change), do: false

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
  # expired or belongs to someone else authorizes nothing.
  defp fetch_session(%User{id: user_id}, session_token) when is_binary(session_token) do
    {:ok, query} = UserToken.verify_session_token_query(session_token)

    case query |> exclude(:select) |> select([token], token) |> Repo.one() do
      %UserToken{user_id: ^user_id} = token -> {:ok, token}
      _ -> :error
    end
  end

  defp fetch_session(_user, _session_token), do: :error

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
