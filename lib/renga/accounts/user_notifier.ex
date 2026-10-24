defmodule Renga.Accounts.UserNotifier do
  @moduledoc """
  Delivers account authentication and settings emails.

  This module owns email wording for auth flows so account contexts can request
  delivery without depending on Swoosh message construction details.
  """

  import Swoosh.Email

  alias Renga.Mailer
  alias Renga.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Renga", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver an invitation to join an organization. The link only works for a
  signed-in account that has confirmed this address.
  """
  def deliver_organization_invitation(email, organization_name, role, url) do
    deliver(email, "You're invited to #{organization_name} on Renga", """

    ==============================

    Hi #{email},

    You've been invited to join #{organization_name} on Renga as #{article(role)} #{role}.

    Accept the invitation by visiting the URL below. Sign in, or create an
    account with this email address, first:

    #{url}

    The invitation expires in #{Renga.Accounts.OrganizationInvitation.validity_days()} days. If you weren't expecting it, please ignore this.

    ==============================
    """)
  end

  @doc """
  Tells the person who started an organization export (RFD 20) that its
  archive is ready to download from organization settings until it expires.
  """
  def deliver_export_ready(email, organization_name, expires_at, url) do
    deliver(email, "Your export of #{organization_name} is ready", """

    ==============================

    Hi #{email},

    The export of #{organization_name} you started is ready. Download it from
    organization settings:

    #{url}

    It holds all of the organization's data, so keep it safe. It can be
    downloaded until #{Calendar.strftime(expires_at, "%Y-%m-%d %H:%M UTC")}, when it is deleted.

    ==============================
    """)
  end

  defp article("owner"), do: "an"
  defp article("admin"), do: "an"
  defp article(_role), do: "a"

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver the code that lets an account with no password or second factor
  set its first one (RFD 19).
  """
  def deliver_bootstrap_code(user, code) do
    deliver(user.email, "Your Renga confirmation code", """

    ==============================

    Hi #{user.email},

    Enter this code in Renga to set your first password or add your first
    sign-in factor:

    #{code}

    It expires in #{Renga.Accounts.Recheck.window_minutes()} minutes and works only in the browser where
    you asked for it. If you didn't ask for it, you can ignore this email.

    ==============================
    """)
  end

  @doc """
  Sends the code that makes `email` the login email of an account that has
  none yet (RFD 15).
  """
  def deliver_email_initialization_code(email, code) do
    deliver(email, "Your Renga confirmation code", """

    ==============================

    Hi #{email},

    Enter this code in Renga to make this address your login email:

    #{code}

    It expires in #{Renga.Accounts.Recheck.window_minutes()} minutes and works only in the browser where
    you asked for it. If you didn't ask for it, you can ignore this email.

    ==============================
    """)
  end

  @doc """
  Tells an address about a change to the account's sign-in (RFD 19). It
  links nowhere, so a forged notice cannot lead anywhere either.
  """
  def deliver_security_notice(email, text) do
    deliver(email, "Security notice from Renga", """

    ==============================

    Hi #{email},

    #{text}

    If this was you, there is nothing to do. If it wasn't, sign in to Renga
    and review your account settings, or ask your administrator for help.

    ==============================
    """)
  end
end
