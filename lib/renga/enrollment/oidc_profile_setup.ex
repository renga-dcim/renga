defmodule Renga.Enrollment.OIDCProfileSetup do
  @moduledoc "Validates the narrow, user-configurable boundary for an OIDC enrollment profile."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :selector, :string
    field :issuer, :string
    field :audience, :string
    field :jwks_url, :string
    field :algorithm, :string, default: "RS256"
    field :subject_claim, :string, default: "sub"
    field :subject_cardinality, :string, default: "singleton"
    field :binding_mode, :string, default: "challenge_bound"
    field :authorized_party, :string
    field :required_claim_path, :string
    field :required_claim_value, :string
    field :group_max, :integer
  end

  def changeset(setup, attrs) do
    setup
    |> cast(attrs, [
      :name,
      :selector,
      :issuer,
      :audience,
      :jwks_url,
      :algorithm,
      :subject_claim,
      :subject_cardinality,
      :binding_mode,
      :authorized_party,
      :required_claim_path,
      :required_claim_value,
      :group_max
    ])
    |> validate_required([
      :name,
      :selector,
      :issuer,
      :audience,
      :jwks_url,
      :algorithm,
      :subject_claim,
      :subject_cardinality,
      :binding_mode,
      :required_claim_path,
      :required_claim_value
    ])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:selector, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must use lowercase letters, numbers, dashes, or underscores"
    )
    |> validate_length(:selector, max: 255)
    |> validate_inclusion(:algorithm, ~w(RS256 EdDSA))
    |> validate_inclusion(:subject_cardinality, ~w(singleton group))
    |> validate_inclusion(:binding_mode, ~w(challenge_bound bearer_unbound))
    |> validate_claim_path(:subject_claim)
    |> validate_claim_path(:required_claim_path)
    |> validate_length(:audience, max: 255)
    |> validate_length(:authorized_party, max: 255)
    |> validate_group_max()
    |> validate_oidc_configuration()
  end

  defp validate_claim_path(changeset, field) do
    validate_format(changeset, field, ~r/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$/,
      message: "must be a dot-separated claim path"
    )
  end

  defp validate_group_max(changeset) do
    if get_field(changeset, :subject_cardinality) == "group" do
      changeset
      |> validate_required([:group_max])
      |> validate_number(:group_max, greater_than: 0, less_than_or_equal_to: 10_000)
    else
      changeset
    end
  end

  defp validate_oidc_configuration(changeset) do
    if changeset.valid? and
         Renga.Enrollment.OIDC.validate_configuration(configuration(changeset)) != :ok do
      add_error(changeset, :jwks_url, "does not form a valid secure OIDC configuration")
    else
      changeset
    end
  end

  def configuration(changeset) do
    config = %{
      "issuer" => get_field(changeset, :issuer),
      "audiences" => [get_field(changeset, :audience)],
      "algorithms" => [get_field(changeset, :algorithm)],
      "subject_claim" => path(get_field(changeset, :subject_claim)),
      "required_claims" => [
        %{"path" => path(get_field(changeset, :required_claim_path)), "type" => "string"}
      ],
      "max_token_age_seconds" => 300,
      "max_token_lifetime_seconds" => 600,
      "clock_skew_seconds" => 30,
      "binding_mode" => get_field(changeset, :binding_mode),
      "jwks_url" => get_field(changeset, :jwks_url),
      "http_timeout_ms" => 2_000,
      "max_jwks_staleness_seconds" => 3_600
    }

    case get_field(changeset, :authorized_party) do
      value when is_binary(value) and value != "" -> Map.put(config, "authorized_party", value)
      _ -> config
    end
  end

  def path(value) when is_binary(value), do: String.split(value, ".")
  def path(_), do: []
end
