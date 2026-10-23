defmodule Renga.Accounts.SignInPolicy do
  @moduledoc """
  The deployment's local sign-in policy (RFD 15, "Local sign-in policy").

  Two settings come from the environment at boot:

    * `REGISTRATION`: `open` (the default) or `closed`, which removes
      `/users/register`. New accounts then come only from a provider that
      allows sign-up, or from an operator; an invitation adds an existing
      account to an organization.
    * `LOCAL_SIGN_IN`: `enabled` (the default) or `disabled`, which turns off
      passwords, emailed links, and passkey sign-in, leaving identity
      providers as the only way in. It also closes registration, whose
      accounts would have no way in.

  The one runtime exception is the operator's local recovery override
  (`recover_local/3`), which re-enables local credentials until it expires
  or is revoked and never opens registration.

  With local sign-in disabled and no usable deployment provider, the web
  interface is in recovery mode (`recovery_mode?/0`).
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.LocalSignInOverride, as: Override
  alias Renga.Repo

  @max_override_minutes 24 * 60

  @doc """
  Whether people can create an account at /users/register.

  Registration creates a local account whose only ways in are local
  credentials, so it also needs the environment to enable local sign-in.
  Otherwise the account could never sign in, yet its address would stop the
  owner's provider sign-up, which refuses an email that is already in use.
  An override never opens it.
  """
  def registration_open?,
    do:
      Application.get_env(:renga, :registration, :open) == :open and
        configured_local_sign_in?()

  @doc "Whether local credentials (passwords, emailed links, passkeys) can sign in."
  def local_sign_in?, do: configured_local_sign_in?() or override_active?()

  @doc "Whether the environment enables local sign-in, ignoring any override."
  def configured_local_sign_in?,
    do: Application.get_env(:renga, :local_sign_in, :enabled) == :enabled

  @doc """
  Whether nobody can sign in: local sign-in is off and no deployment
  provider is usable. The web interface then serves only provider test
  links and their callbacks.
  """
  def recovery_mode?, do: not IdentityProviders.sign_in_available?()

  @doc "The override in effect, or nil."
  def active_override do
    now = Renga.Time.utc_now_ms()

    Override
    |> where([override], is_nil(override.revoked_at) and override.expires_at > ^now)
    |> order_by(desc: :expires_at)
    |> limit(1)
    |> Repo.one()
  end

  defp override_active?, do: not is_nil(active_override())

  @doc """
  Checks, inside the transaction that issues a session, that local
  credentials may sign in now. Returns `{:ok, nil}` when the environment
  enables local sign-in, `{:ok, override_id}` when only an override does, and
  `{:error, :local_sign_in_disabled}` otherwise.

  The override's row stays share-locked until the sign-in commits, so a
  revocation running alongside waits for it: a sign-in either committed
  before the override was revoked, or is refused.
  """
  def local_sign_in_grant do
    if configured_local_sign_in?() do
      {:ok, nil}
    else
      now = Renga.Time.utc_now_ms()

      Override
      |> where([override], is_nil(override.revoked_at) and override.expires_at > ^now)
      |> order_by(desc: :expires_at)
      |> limit(1)
      |> lock("FOR SHARE")
      |> select([override], override.id)
      |> Repo.one()
      |> case do
        nil -> {:error, :local_sign_in_disabled}
        id -> {:ok, id}
      end
    end
  end

  @doc """
  Turns local sign-in on for `minutes`, at most a day, recording `actor`.
  With `disable: provider_id`, also disables that provider in the same
  serialized change, so a broken sole provider can be taken out of service
  without locking everyone out.
  """
  def recover_local(minutes, actor, opts \\ [])
      when is_integer(minutes) and minutes > 0 and minutes <= @max_override_minutes and
             is_binary(actor) do
    # Disabling the provider can remove SCIM grants (RFD 16); open pages
    # hear of it only once this transaction, not the nested one, commits.
    Renga.Scim.Grants.announcing(fn -> recover(minutes, actor, opts) end)
  end

  defp recover(minutes, actor, opts) do
    Repo.transaction(fn ->
      override =
        Repo.insert!(%Override{
          expires_at: DateTime.add(Renga.Time.utc_now_ms(), minutes, :minute),
          created_by: actor
        })

      case disable(opts[:disable], actor) do
        {:ok, _provider} -> override
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp disable(nil, _actor), do: {:ok, nil}

  defp disable(id, actor) do
    case IdentityProviders.get(id) do
      nil -> {:error, :not_found}
      provider -> IdentityProviders.disable(provider, {:operator, actor})
    end
  end

  @doc "Ends every override now."
  def revoke_overrides(actor) when is_binary(actor) do
    now = Renga.Time.utc_now_ms()

    {count, _} =
      Override
      |> where([override], is_nil(override.revoked_at) and override.expires_at > ^now)
      |> Repo.update_all(set: [revoked_at: now, revoked_by: actor])

    {:ok, count}
  end
end
