defmodule Renga.Accounts.IdentityProviderRevision do
  @moduledoc """
  One version of a provider's authentication settings (RFD 15, "Storage and
  changes"). A revision is written once and never edited: a change makes a
  new pending revision, which takes effect only when activated. The client
  secret is stored encrypted by `Renga.Vault` and never read back for
  display.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @default_lifetime 12 * 60 * 60
  @min_lifetime 5 * 60
  @max_lifetime 30 * 24 * 60 * 60
  # RFC 6749 scope tokens: printable ASCII except space, quote, and backslash.
  @scope_format ~r/^[\x21\x23-\x5B\x5D-\x7E]{1,64}$/
  @domain_format ~r/^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/

  # What a new revision copies from the one it replaces.
  @carried ~w(client_id client_secret_ciphertext client_secret_key_id client_secret_set_at
              scopes email_domains allow_sign_up session_lifetime_seconds)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "identity_provider_revisions" do
    field :number, :integer
    field :client_id, :string
    field :client_secret_ciphertext, :binary, redact: true
    field :client_secret_key_id, :string
    field :client_secret_set_at, :utc_datetime_usec
    field :scopes, {:array, :string}, default: []
    field :email_domains, {:array, :string}, default: []
    field :allow_sign_up, :boolean, default: false
    field :session_lifetime_seconds, :integer, default: @default_lifetime
    field :created_by, :string

    # The plaintext only passes through a changeset on its way to the vault.
    field :client_secret, :string, virtual: true, redact: true

    belongs_to :provider, Renga.Accounts.IdentityProvider, type: :string

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {Renga.Time, :utc_now_ms, []},
      updated_at: false
    )
  end

  @doc "The settings a revision carries, in the order changes are reported."
  def fields,
    do: ~w(client_id client_secret scopes email_domains allow_sign_up session_lifetime_seconds)a

  @doc """
  A changeset for a new revision. `base` is the revision it replaces, whose
  settings, including the encrypted secret, carry over unless `attrs` change
  them; an empty client secret keeps the saved one.
  """
  def changeset(%__MODULE__{} = base, attrs, kind) do
    attrs = drop_blank_secret(attrs)

    __MODULE__
    |> struct(Map.take(base, @carried))
    |> cast(attrs, fields())
    |> validate_required([:client_id, :session_lifetime_seconds])
    |> update_change(:client_id, &String.trim/1)
    |> validate_length(:client_id, max: 255)
    |> validate_length(:client_secret, max: 1024)
    |> validate_secret_present()
    |> update_change(:scopes, &normalize_list(&1, false))
    |> validate_length(:scopes, max: 20)
    |> validate_items(:scopes, @scope_format, "contains an invalid scope")
    |> update_change(:email_domains, &normalize_list(&1, true))
    |> validate_length(:email_domains, max: 50)
    |> validate_items(:email_domains, @domain_format, "contains an invalid domain")
    |> validate_number(:session_lifetime_seconds,
      greater_than_or_equal_to: @min_lifetime,
      less_than_or_equal_to: @max_lifetime
    )
    |> validate_sign_up(kind)
  end

  defp drop_blank_secret(attrs) do
    Map.reject(attrs, fn {key, value} ->
      to_string(key) == "client_secret" and (is_nil(value) or String.trim(value) == "")
    end)
  end

  defp validate_secret_present(changeset) do
    if get_field(changeset, :client_secret) || get_field(changeset, :client_secret_ciphertext),
      do: changeset,
      else: add_error(changeset, :client_secret, "can't be blank")
  end

  # GitHub cannot show that a sign-in is fresh, so it may only be linked to
  # an existing account, never create one (RFD 15).
  defp validate_sign_up(changeset, "github") do
    if get_field(changeset, :allow_sign_up),
      do: add_error(changeset, :allow_sign_up, "is not available for GitHub"),
      else: changeset
  end

  defp validate_sign_up(changeset, _kind), do: changeset

  defp normalize_list(values, downcase?) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.map(&if(downcase?, do: String.downcase(&1), else: &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_items(changeset, field, format, message) do
    validate_change(changeset, field, fn ^field, values ->
      if Enum.all?(values, &Regex.match?(format, &1)), do: [], else: [{field, message}]
    end)
  end
end
