defmodule Renga.Accounts.SecurityLog do
  @moduledoc """
  Each account's security log and email notices (RFD 19, "Security log and
  notices").

  The log holds sign-ins, failed second steps, and every credential change,
  and the settings page shows it. Credential changes, and spending a
  recovery code, also send a notice to the account's email address so a
  change made from a stolen session does not go unnoticed. Rate limits for
  second-factor codes count the failures recorded here.
  """

  import Ecto.Query

  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.User
  alias Renga.Accounts.UserNotifier
  alias Renga.Repo

  @descriptions %{
    "signed_in" => "Signed in",
    "totp_added" => "Authenticator app added",
    "totp_removed" => "Authenticator app removed",
    "totp_failed" => "Wrong authenticator code",
    "totp_enable_failed" => "Wrong code while adding an authenticator app",
    "passkey_added" => "Passkey added",
    "passkey_removed" => "Passkey removed",
    "passkey_failed" => "Passkey check failed",
    "recovery_codes_generated" => "New recovery codes generated",
    "recovery_code_used" => "Recovery code used",
    "recovery_code_failed" => "Wrong recovery code",
    "second_factor_rate_limited" => "Second step refused after too many wrong attempts",
    "password_changed" => "Password changed",
    "password_removed" => "Password removed",
    "email_changed" => "Email address changed",
    "mfa_removed_by_operator" => "Second factors removed by an operator"
  }

  # What each notice says happened. Failures and sign-ins are logged only.
  @notices %{
    "totp_added" => "An authenticator app was added to your Renga account.",
    "totp_removed" => "The authenticator app was removed from your Renga account.",
    "passkey_added" => "A passkey was added to your Renga account.",
    "passkey_removed" => "A passkey was removed from your Renga account.",
    "recovery_codes_generated" =>
      "New recovery codes were generated for your Renga account. The old ones no longer work.",
    "recovery_code_used" => "A recovery code was used to sign in to your Renga account.",
    "password_changed" => "The password of your Renga account was changed.",
    "password_removed" => "The password was removed from your Renga account.",
    "email_changed" => "The email address of your Renga account was changed."
  }

  @doc "Records an event in the account's security log."
  def record(%User{id: user_id}, kind, metadata \\ %{}) when is_map_key(@descriptions, kind) do
    Repo.insert!(%SecurityEvent{user_id: user_id, kind: kind, metadata: metadata})
  end

  @doc """
  Emails the notice for `kind`, if it has one. Called once the change has
  committed, so a rolled-back change sends nothing. An email change also
  tells the old address.
  """
  def notify(%User{} = user, kind, opts \\ []) do
    case @notices do
      %{^kind => text} ->
        UserNotifier.deliver_security_notice(user.email, text)

        if previous = opts[:previous_email],
          do: UserNotifier.deliver_security_notice(previous, text)

        :ok

      _ ->
        :ok
    end
  end

  @doc "The account's most recent events, newest first."
  def list(%User{id: user_id}, limit \\ 20) do
    SecurityEvent
    |> where(user_id: ^user_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "A person-readable line for an event."
  def describe(%SecurityEvent{kind: kind, metadata: metadata}) do
    description = Map.fetch!(@descriptions, kind)

    case metadata do
      %{"method" => method} -> "#{description} with #{method_label(method)}"
      %{"actor" => actor} -> "#{description} (#{actor})"
      _ -> description
    end
  end

  defp method_label("passkey"), do: "a passkey"
  defp method_label("password"), do: "a password"
  defp method_label("magic_link"), do: "an emailed link"
  defp method_label("totp"), do: "an authenticator code"
  defp method_label("recovery_code"), do: "a recovery code"
  defp method_label(other), do: other
end
