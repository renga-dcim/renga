defmodule Renga.Accounts.OrganizationDomain do
  @moduledoc """
  An email domain an organization claims for routing sign-in to its identity
  provider (RFD 15, "Organization providers"). The claim routes nobody until
  the organization publishes `token` in a DNS TXT record and Renga sees it;
  only one organization at a time may have a domain verified.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  # A host name of at least two labels, such as example.com.
  @domain_format ~r/^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$/

  schema "organization_domains" do
    field :domain, :string
    field :token, :string, redact: true
    field :verified_at, :utc_datetime_usec
    field :checked_at, :utc_datetime_usec

    belongs_to :organization, Organization

    timestamps()
  end

  @doc "A new, unverified claim on a domain with a fresh verification token."
  def create_changeset(organization_id, attrs) do
    %__MODULE__{organization_id: organization_id}
    |> cast(attrs, [:domain])
    |> update_change(:domain, &normalize/1)
    |> validate_required([:domain])
    |> validate_format(:domain, @domain_format, message: "must be a domain such as example.com")
    |> put_change(:token, Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))
    |> unique_constraint(:domain,
      name: :organization_domains_organization_id_domain_index,
      message: "is already listed"
    )
  end

  defp normalize(domain) do
    domain |> String.trim() |> String.downcase() |> String.trim_trailing(".")
  end
end
