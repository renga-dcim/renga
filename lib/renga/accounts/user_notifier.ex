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
end
