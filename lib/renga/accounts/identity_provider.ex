defmodule Renga.Accounts.IdentityProvider do
  @moduledoc """
  An identity provider people sign in with (RFD 15, "Providers"). The ID,
  kind, issuer, and owning organization never change once the provider is
  saved; authentication settings live in `IdentityProviderRevision`s. Only
  the display fields here change in place.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(oidc github)
  @id_format ~r/^[a-z0-9](?:[a-z0-9-]{0,46}[a-z0-9])?$/
  @icons ~w(generic google microsoft okta keycloak github gitlab)

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  schema "identity_providers" do
    field :kind, :string
    field :issuer, :string
    field :display_name, :string
    field :icon, :string
    field :hidden, :boolean, default: false
    field :enabled, :boolean, default: true
    field :active_revision, :integer
    field :pending_revision, :integer
    field :version, :integer, default: 1
    field :removed_at, :utc_datetime_usec

    belongs_to :organization, Renga.Accounts.Organization

    timestamps(type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []})
  end

  def kinds, do: @kinds
  def icons, do: @icons

  @doc """
  A changeset for a new provider: its permanent identity and display fields.
  With `organization_id`, it is that organization's provider (RFD 15,
  "Organization providers"): always OpenID Connect over https, and never
  hidden, since its people reach it from the organization's sign-in link.
  """
  def create_changeset(provider, attrs, organization_id \\ nil)

  def create_changeset(provider, attrs, nil) do
    provider
    |> cast(attrs, [:id, :kind, :issuer, :display_name, :icon, :hidden])
    |> identity_validations()
  end

  def create_changeset(provider, attrs, organization_id) do
    provider
    |> cast(attrs, [:id, :kind, :issuer, :display_name, :icon])
    |> put_change(:organization_id, organization_id)
    |> put_change(:hidden, false)
    |> validate_inclusion(:kind, ["oidc"], message: "must be OpenID Connect for an organization")
    |> identity_validations()
    |> validate_https_issuer()
  end

  # The loopback http issuer allowed for local development is never an
  # organization's.
  defp validate_https_issuer(changeset) do
    issuer = get_field(changeset, :issuer)

    if is_binary(issuer) and not Keyword.has_key?(changeset.errors, :issuer) and
         not match?(%URI{scheme: "https"}, URI.parse(issuer)),
       do: add_error(changeset, :issuer, "must be an https URL"),
       else: changeset
  end

  defp identity_validations(changeset) do
    changeset
    |> validate_required([:id, :kind, :display_name])
    |> update_change(:id, &String.downcase/1)
    |> validate_format(:id, @id_format,
      message: "use lowercase letters, digits, and dashes, up to 48 characters"
    )
    |> validate_inclusion(:kind, @kinds)
    |> validate_issuer()
    |> display_validations()
    |> unique_constraint(:id, name: :identity_providers_pkey, message: "is already taken")
  end

  @doc "A changeset for the fields that change without a new revision."
  def display_changeset(%__MODULE__{organization_id: nil} = provider, attrs) do
    provider
    |> cast(attrs, [:display_name, :icon, :hidden])
    |> validate_required([:display_name])
    |> display_validations()
  end

  def display_changeset(provider, attrs) do
    provider
    |> cast(attrs, [:display_name, :icon])
    |> validate_required([:display_name])
    |> display_validations()
  end

  defp display_validations(changeset) do
    changeset
    |> update_change(:display_name, &String.trim/1)
    |> validate_length(:display_name, max: 80)
    |> validate_inclusion(:icon, @icons)
  end

  # OpenID Connect discovery needs an https issuer; GitHub has none. A
  # loopback issuer over http is allowed for local development.
  defp validate_issuer(changeset) do
    case get_field(changeset, :kind) do
      "oidc" -> validate_oidc_issuer(changeset)
      _other -> validate_no_issuer(changeset)
    end
  end

  defp validate_oidc_issuer(changeset) do
    changeset
    |> validate_required([:issuer])
    |> update_change(:issuer, &String.trim/1)
    |> validate_change(:issuer, fn :issuer, issuer ->
      if valid_issuer?(issuer), do: [], else: [issuer: "must be an https URL without a query"]
    end)
  end

  defp validate_no_issuer(changeset) do
    if get_field(changeset, :issuer),
      do: add_error(changeset, :issuer, "is only for OpenID Connect providers"),
      else: changeset
  end

  defp valid_issuer?(issuer) do
    case URI.parse(issuer) do
      %URI{scheme: "https", host: host, query: nil, fragment: nil, userinfo: nil}
      when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host, query: nil, fragment: nil, userinfo: nil}
      when host in ["localhost", "127.0.0.1"] ->
        true

      _other ->
        false
    end
  end
end
