defmodule Renga.Accounts.OrganizationDomains do
  @moduledoc """
  Email domains that route sign-in to an organization's identity provider
  (RFD 15, "Organization providers"). An owner claims a domain, publishes
  the TXT record Renga shows, and checks it; from then on someone entering
  an address at that domain on the main sign-in page is sent to the
  organization's sign-in link.

  Only one organization at a time has a domain verified. Another
  organization's claim succeeds only once the holder's record is gone,
  which its check finds then and there. Every verified domain is checked
  again daily (`Renga.Accounts.OrganizationDomains.Worker`): a record that
  is definitely gone unverifies it, while a DNS failure leaves it as it
  was.

  Changes need `organization.manage`, checked in the transaction that makes
  them, and appear in the organization's Activity.
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.OrganizationDomain
  alias Renga.Accounts.Scope
  alias Renga.Authorization
  alias Renga.Inventory.ChangeEvent
  alias Renga.Repo

  @permission "organization.manage"
  @record_prefix "_renga-verification."
  @value_prefix "renga-verification="

  @doc "The organization's claimed domains, by name."
  def list(%Scope{organization_id: organization_id}) when is_binary(organization_id) do
    OrganizationDomain
    |> where(organization_id: ^organization_id)
    |> order_by(asc: :domain)
    |> Repo.all()
  end

  @doc "The DNS name to publish the verification record at."
  def record_name(%OrganizationDomain{domain: domain}), do: @record_prefix <> domain

  @doc "The TXT record's value."
  def record_value(%OrganizationDomain{token: token}), do: @value_prefix <> token

  @doc "Claims `domain` for the organization, unverified."
  def add(%Scope{} = scope, domain) when is_binary(domain) do
    authorized(scope, fn ->
      with {:ok, claim} <-
             scope.organization_id
             |> OrganizationDomain.create_changeset(%{domain: domain})
             |> Repo.insert() do
        record!(scope, claim, "added")
        {:ok, claim}
      end
    end)
  end

  @doc """
  Looks up the claim's TXT record now and verifies the domain if it holds
  the token. Returns `{:ok, claim}`, or `{:error, reason}` with
  `:record_not_found`, `:dns_unavailable`, or `:verified_elsewhere` when
  another organization still proves control of it.
  """
  def verify(%Scope{} = scope, %OrganizationDomain{id: id}) do
    with {:ok, claim} <- fetch(scope, id),
         {:ok, :found} <- check(claim) do
      authorized(scope, fn -> claim_verified(scope, id) end)
    else
      {:ok, :missing} -> {:error, :record_not_found}
      {:ok, :unavailable} -> {:error, :dns_unavailable}
      error -> error
    end
  end

  defp claim_verified(scope, id) do
    case lock_claim(scope, id) do
      nil -> {:error, :not_found}
      %OrganizationDomain{verified_at: %DateTime{}} = claim -> {:ok, claim}
      claim -> take_over(scope, claim)
    end
  end

  # The domain is this organization's unless another still holds it and
  # still proves control; a holder whose record is gone loses it here.
  defp take_over(scope, claim) do
    holder =
      OrganizationDomain
      |> where([d], d.domain == ^claim.domain and not is_nil(d.verified_at))
      |> lock("FOR UPDATE")
      |> Repo.one()

    case holder && check(holder) do
      nil ->
        mark_verified(scope, claim)

      {:ok, :missing} ->
        unverify!(holder)
        mark_verified(scope, claim)

      {:ok, _found_or_unavailable} ->
        {:error, :verified_elsewhere}
    end
  end

  defp mark_verified(scope, claim) do
    now = Renga.Time.utc_now_ms()

    # Two organizations verifying at once both find no holder; the index
    # lets only one of them through.
    claim
    |> Ecto.Changeset.change(verified_at: now, checked_at: now)
    |> Ecto.Changeset.unique_constraint(:domain, name: :organization_domains_one_verified_index)
    |> Repo.update()
    |> case do
      {:ok, claim} ->
        record!(scope, claim, "verified")
        {:ok, claim}

      {:error, _changeset} ->
        {:error, :verified_elsewhere}
    end
  end

  @doc "Removes the claim, and with it any routing to the organization."
  def remove(%Scope{} = scope, %OrganizationDomain{id: id}) do
    authorized(scope, fn ->
      case lock_claim(scope, id) do
        nil ->
          {:error, :not_found}

        claim ->
          Repo.delete!(claim)
          record!(scope, claim, "removed")
          {:ok, claim}
      end
    end)
  end

  @doc """
  Checks every verified domain's record again. A record that is definitely
  gone unverifies the domain; a DNS failure leaves it verified until the
  next check. For `Renga.Accounts.OrganizationDomains.Worker`.
  """
  def recheck_verified do
    OrganizationDomain
    |> where([d], not is_nil(d.verified_at))
    |> Repo.all()
    |> Enum.each(&recheck/1)
  end

  defp recheck(claim) do
    case check(claim) do
      {:ok, :found} ->
        Repo.update_all(where(OrganizationDomain, id: ^claim.id),
          set: [checked_at: Renga.Time.utc_now_ms()]
        )

      {:ok, :missing} ->
        Repo.transaction(fn -> unverify_if_verified(claim.id) end)

      {:ok, :unavailable} ->
        :ok
    end
  end

  defp unverify_if_verified(id) do
    case Repo.one(
           from d in OrganizationDomain,
             where: d.id == ^id and not is_nil(d.verified_at),
             lock: "FOR UPDATE"
         ) do
      nil -> :ok
      claim -> unverify!(claim)
    end
  end

  defp unverify!(claim) do
    claim
    |> Ecto.Changeset.change(verified_at: nil, checked_at: Renga.Time.utc_now_ms())
    |> Repo.update!()

    record!(%Scope{organization_id: claim.organization_id}, claim, "unverified")
  end

  @doc "Whether any organization has a verified domain, so sign-in offers routing."
  def any_verified? do
    Repo.exists?(where(OrganizationDomain, [d], not is_nil(d.verified_at)))
  end

  @doc """
  The slug of the organization whose verified domain is the domain of
  `email` and that has a provider people can sign in with now, or nil. Only
  the exact domain counts, not its subdomains.
  """
  def organization_slug_for_email(email) when is_binary(email) do
    with [_local, domain] when domain != "" <-
           email |> String.trim() |> String.downcase() |> String.split("@"),
         slug when is_binary(slug) <-
           Repo.one(
             from d in OrganizationDomain,
               join: o in assoc(d, :organization),
               where: d.domain == ^domain and not is_nil(d.verified_at),
               where: o.status == "active",
               select: o.slug
           ),
         {_organization, [_ | _]} <- IdentityProviders.organization_sign_in_options(slug) do
      slug
    else
      _none -> nil
    end
  end

  def organization_slug_for_email(_email), do: nil

  # Whether the claim's record holds its token: `:found`, `:missing` when
  # DNS answers that it does not, or `:unavailable` when DNS gave no answer.
  defp check(claim) do
    resolver = Application.get_env(:renga, :dns_txt_resolver, &lookup_txt/1)

    case resolver.(record_name(claim)) do
      {:ok, values} ->
        if record_value(claim) in values, do: {:ok, :found}, else: {:ok, :missing}

      {:error, :nxdomain} ->
        {:ok, :missing}

      {:error, _reason} ->
        {:ok, :unavailable}
    end
  end

  @doc false
  def lookup_txt(name) do
    # The option bounds each try; the fifth argument bounds the whole lookup,
    # which otherwise retries every nameserver with no overall deadline.
    case :inet_res.resolve(String.to_charlist(name), :in, :txt, [timeout: 2_000], 5_000) do
      {:ok, message} ->
        values =
          for record <- :inet_dns.msg(message, :anlist),
              :inet_dns.rr(record, :type) == :txt,
              do: record |> :inet_dns.rr(:data) |> Enum.map_join(&to_string/1)

        {:ok, values}

      {:error, :nxdomain} ->
        {:error, :nxdomain}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch(%Scope{organization_id: organization_id}, id) when is_binary(organization_id) do
    case Repo.get_by(OrganizationDomain, id: id, organization_id: organization_id) do
      nil -> {:error, :not_found}
      claim -> {:ok, claim}
    end
  end

  defp fetch(_scope, _id), do: {:error, :forbidden}

  defp lock_claim(%Scope{organization_id: organization_id}, id) do
    Repo.one(
      from d in OrganizationDomain,
        where: d.id == ^id and d.organization_id == ^organization_id,
        lock: "FOR UPDATE"
    )
  end

  defp authorized(%Scope{organization_id: organization_id} = scope, fun)
       when is_binary(organization_id) do
    Repo.transaction(fn ->
      Authorization.authorize!(scope, @permission, lock: :share)

      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp authorized(_scope, _fun), do: {:error, :forbidden}

  defp record!(%Scope{} = scope, claim, change) do
    %ChangeEvent{
      organization_id: claim.organization_id,
      actor_user_id: scope.user && scope.user.id
    }
    |> ChangeEvent.changeset(%{
      kind: "organization_domain_changed",
      field: claim.domain,
      metadata: %{"domain" => claim.domain, "change" => change},
      occurred_at: Renga.Time.utc_now_ms()
    })
    |> Repo.insert!()
  end
end
