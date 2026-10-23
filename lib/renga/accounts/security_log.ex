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

  require Logger

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
    "second_factor_confirmed" =>
      "Second factor confirmed to open an organization that requires MFA",
    "password_changed" => "Password changed",
    "password_removed" => "Password removed",
    "email_changed" => "Email address changed",
    "email_initialized" => "Login email set up",
    "email_initialization_code_sent" => "Login email code sent",
    "mfa_removed_by_operator" => "Second factors removed by an operator",
    "identity_linked" => "Identity provider connected",
    "identity_unlinked" => "Identity provider disconnected"
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
    "email_changed" => "The email address of your Renga account was changed.",
    "mfa_removed_by_operator" =>
      "An operator removed every passkey, the authenticator app, and the recovery codes from your Renga account.",
    "identity_linked" =>
      "An identity provider was connected to your Renga account. You can now sign in with it.",
    "identity_unlinked" =>
      "An identity provider was disconnected from your Renga account. It no longer signs you in."
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
  def notify(%User{id: user_id} = user, kind, opts \\ []) do
    case @notices do
      %{^kind => text} ->
        # The stored address, not the caller's copy, which a change made
        # elsewhere may have outdated.
        email = Repo.one(from u in User, where: u.id == ^user_id, select: u.email) || user.email

        # An account an organization's provider created may have no email.
        [email | List.wrap(opts[:previous_email])]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&deliver(&1, kind, text))
        |> Enum.find(:ok, &(&1 != :ok))

      _ ->
        :ok
    end
  end

  # Delivery is best effort: the change already committed. A failure is
  # logged for the operator and returned.
  defp deliver(email, kind, text) do
    case UserNotifier.deliver_security_notice(email, text) do
      {:ok, _email} ->
        :ok

      {:error, reason} ->
        Logger.warning("Security notice #{kind} could not be sent: #{inspect(reason)}")
        {:error, reason}
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
      %{"method" => method, "local_override" => _} ->
        "#{description} with #{method_label(method)} during a local sign-in override"

      %{"method" => method} ->
        "#{description} with #{method_label(method)}"

      %{"actor" => actor} ->
        "#{description} (#{actor})"

      %{"provider" => id} ->
        "#{description}: #{provider_label(id)}"

      _ ->
        description
    end
  end

  defp method_label("passkey"), do: "a passkey"
  defp method_label("password"), do: "a password"
  defp method_label("magic_link"), do: "an emailed link"
  defp method_label("totp"), do: "an authenticator code"
  defp method_label("recovery_code"), do: "a recovery code"
  defp method_label("provider:" <> id), do: "the identity provider #{provider_label(id)}"
  defp method_label(other), do: other

  # A provider's display name can change and its row outlives removal, so
  # the log stores the ID and names it as it is now.
  defp provider_label(id) do
    case Repo.get(Renga.Accounts.IdentityProvider, id) do
      %{display_name: name} -> name
      nil -> id
    end
  end
end
