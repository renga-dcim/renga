defmodule Renga.Operators.InvitationDeliveries do
  @moduledoc """
  Durable email delivery for owner invitations created by an operator.

  The invitation transaction encrypts and stores its URL before it commits.
  Delivery happens only outside that transaction. A short database lease lets
  every node retry pending rows without holding a transaction open while it
  calls the mail provider. Provider acceptance cannot be made exactly-once:
  after an ambiguous timeout the same invitation may be emailed again, but a
  retry never creates a different invitation or loses the durable intent.
  """

  import Ecto.Query

  require Logger

  alias Renga.Accounts.OrganizationInvitation
  alias Renga.Accounts.UserNotifier
  alias Renga.Operators.InvitationDelivery
  alias Renga.Operators.OperatorToken
  alias Renga.Repo
  alias Renga.Vault

  @batch_size 100
  @lease_seconds 60
  @max_retry_seconds 3_600

  @doc "Stores an encrypted delivery intent in the caller's transaction."
  def enqueue(invitation, token, url_fun) when is_function(url_fun, 1) do
    id = Ecto.UUID.generate()

    case Vault.encrypt(url_fun.(token), aad(id)) do
      {:ok, key_id, ciphertext} ->
        delivery =
          Repo.insert!(%InvitationDelivery{
            id: id,
            invitation_id: invitation.id,
            url_ciphertext: ciphertext,
            url_key_id: key_id,
            available_at: Renga.Time.utc_now_ms()
          })

        {:ok, delivery}

      {:error, :no_key} ->
        {:error, :secret_storage_unavailable}
    end
  end

  @doc """
  Attempts one invitation's pending delivery after commit. Inside a caller's
  transaction it deliberately does nothing; the periodic sweep recovers the
  row after that outer transaction commits.
  """
  def dispatch(invitation_id, now \\ Renga.Time.utc_now_ms()) do
    if Repo.in_transaction?() do
      :deferred
    else
      invitation_id
      |> claim(now)
      |> deliver(now)
    end
  rescue
    _error ->
      Logger.error("Operator invitation delivery failed before dispatch; it remains queued")

      {:error, :temporary_failure}
  catch
    _kind, _reason ->
      Logger.error("Operator invitation delivery failed before dispatch; it remains queued")

      {:error, :temporary_failure}
  end

  @doc "Attempts each currently available delivery once. Safe on every node."
  def sweep(now \\ nil)

  def sweep(nil) do
    now = Renga.Time.utc_now_ms()
    sweep_available(now, fn id -> dispatch(id) end)
  end

  def sweep(%DateTime{} = now) do
    sweep_available(now, fn id -> dispatch(id, now) end)
  end

  defp sweep_available(now, dispatch) do
    ids =
      InvitationDelivery
      |> available(now)
      |> order_by([delivery], asc: delivery.available_at, asc: delivery.id)
      |> limit(@batch_size)
      |> select([delivery], delivery.invitation_id)
      |> Repo.all()

    Enum.reduce(ids, %{delivered: 0, pending: 0, discarded: 0}, fn id, counts ->
      case dispatch.(id) do
        :ok -> Map.update!(counts, :delivered, &(&1 + 1))
        :discarded -> Map.update!(counts, :discarded, &(&1 + 1))
        _pending -> Map.update!(counts, :pending, &(&1 + 1))
      end
    end)
  end

  defp claim(invitation_id, now) do
    {:ok, delivery} =
      Repo.transaction(fn ->
        delivery =
          InvitationDelivery
          |> where([delivery], delivery.invitation_id == ^invitation_id)
          |> available(now)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> preload([delivery], invitation: :organization)
          |> Repo.one()

        claim_delivery(delivery, now)
      end)

    delivery
  end

  defp claim_delivery(nil, _now), do: nil

  defp claim_delivery(%InvitationDelivery{invitation: invitation} = delivery, now) do
    cond do
      not OrganizationInvitation.open?(invitation, now) or not live_operator?(invitation) ->
        Repo.delete!(delivery)
        :discarded

      invitation.organization.status != "active" ->
        postpone(delivery, now)
        nil

      true ->
        lease_id = Ecto.UUID.generate()

        delivery
        |> Ecto.Changeset.change(
          attempts: delivery.attempts + 1,
          lease_id: lease_id,
          lease_expires_at: DateTime.add(now, @lease_seconds, :second)
        )
        |> Repo.update!()
    end
  end

  defp deliver(nil, _now), do: :pending
  defp deliver(:discarded, _now), do: :discarded

  defp deliver(%InvitationDelivery{} = delivery, now) do
    invitation = delivery.invitation

    result =
      with {:ok, url} <-
             Vault.decrypt(delivery.url_key_id, delivery.url_ciphertext, aad(delivery.id)),
           {:ok, _email} <-
             UserNotifier.deliver_organization_invitation(
               invitation.email,
               invitation.organization.name,
               invitation.role,
               url
             ) do
        :ok
      else
        _unavailable_or_ambiguous -> {:error, :delivery_failed}
      end

    case result do
      :ok ->
        Repo.delete_all(owned_lease(delivery))
        :ok

      {:error, :delivery_failed} ->
        retry(delivery, now)
        {:error, :delivery_failed}
    end
  end

  defp retry(delivery, now) do
    delivery
    |> owned_lease()
    |> Repo.update_all(
      set: [
        available_at: DateTime.add(now, retry_seconds(delivery.attempts), :second),
        lease_id: nil,
        lease_expires_at: nil,
        updated_at: now
      ]
    )

    :ok
  end

  defp postpone(delivery, now) do
    delivery
    |> Ecto.Changeset.change(
      available_at: DateTime.add(now, @lease_seconds, :second),
      lease_id: nil,
      lease_expires_at: nil
    )
    |> Repo.update!()
  end

  defp available(query, now) do
    where(
      query,
      [delivery],
      delivery.available_at <= ^now and
        (is_nil(delivery.lease_expires_at) or delivery.lease_expires_at <= ^now)
    )
  end

  defp owned_lease(delivery) do
    where(
      InvitationDelivery,
      [pending],
      pending.id == ^delivery.id and pending.lease_id == ^delivery.lease_id
    )
  end

  defp live_operator?(%OrganizationInvitation{invited_by_operator_token_id: nil}), do: true

  defp live_operator?(%OrganizationInvitation{invited_by_operator_token_id: token_id}) do
    OperatorToken
    |> where([token], token.id == ^token_id and is_nil(token.revoked_at))
    |> Repo.exists?()
  end

  defp retry_seconds(attempts) do
    min(5 * Integer.pow(2, min(attempts - 1, 9)), @max_retry_seconds)
  end

  defp aad(id), do: "renga.operator_invitation_delivery:#{id}"
end
