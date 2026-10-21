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
  """

  alias Renga.Accounts.IdentityProviderRevision, as: Revision
  alias Renga.Accounts.User
  alias Renga.Accounts.UserIdentity
  alias Renga.Repo

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
        %UserIdentity{} = identity -> {:ok, returning(identity, email)}
        nil -> first_sign_in(provider, revision, subject, email)
      end
    end
  end

  defp returning(identity, email) do
    identity
    |> Ecto.Changeset.change(
      email: email && email.address,
      last_signed_in_at: Renga.Time.utc_now_ms()
    )
    |> Repo.update!()

    Repo.get!(User, identity.user_id)
  end

  defp first_sign_in(provider, revision, subject, email) do
    # Only a verified address is said to be in use, so an unverified claim
    # cannot ask whether an account exists.
    cond do
      email && email.verified && Repo.get_by(User, email: email.address) ->
        {:error, :email_in_use}

      not revision.allow_sign_up ->
        {:error, :sign_up_closed}

      is_nil(email) or not email.verified ->
        {:error, :unverified_email}

      true ->
        sign_up(provider, subject, email.address)
    end
  end

  defp sign_up(provider, subject, address) do
    Repo.transact(fn ->
      with {:ok, user} <-
             %User{}
             |> User.email_changeset(%{email: address})
             |> Ecto.Changeset.put_change(:confirmed_at, Renga.Time.utc_now_ms())
             |> Repo.insert() do
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
          {:ok, _identity} -> {:ok, user}
          # A concurrent first sign-in by the same subject linked it first.
          {:error, _changeset} -> {:error, :already_linked}
        end
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, :already_linked} -> {:error, :already_linked}
      {:error, %Ecto.Changeset{} = changeset} -> sign_up_error(changeset)
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
