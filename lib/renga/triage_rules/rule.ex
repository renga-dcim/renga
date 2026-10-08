defmodule Renga.TriageRules.Rule do
  @moduledoc """
  One triage rule (RFD 8, "Triage"): a strong signal that sets one missing
  fact. The kinds are fixed so every rule stays readable at a glance:

    * `network_location` - reports from a subnet, or through an intake key,
      put a resource at a site (and optionally a location);
    * `top_of_rack` - a resource whose LLDP neighbor is a switch placed in a
      rack goes in that rack, never at a rack unit;
    * `ownership` - a hostname pattern, or a label the collector sends, sets
      the owning team.

  The changeset clears the fields a kind does not use so the stored shape
  always matches the database check.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Renga.Accounts.Organization

  @kinds ~w(network_location top_of_rack ownership)
  @fields ~w(subnet intake_api_key_id hostname_pattern label_key label_value site_id
             location_id team_id)a
  @kind_fields %{
    "network_location" => ~w(subnet intake_api_key_id site_id location_id)a,
    "top_of_rack" => [],
    "ownership" => ~w(hostname_pattern label_key label_value team_id)a
  }
  # Hostname patterns are globs over normalized (lowercase) hostnames; `*`
  # is the only wildcard, so a pattern can never smuggle SQL LIKE syntax.
  @hostname_pattern ~r/\A[a-z0-9.\-_*]+\z/
  # Same shape the intake API accepts for collector labels.
  @label_key ~r/\A[A-Za-z0-9]([A-Za-z0-9._\/-]*[A-Za-z0-9])?\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {Renga.Time, :utc_now_ms, []}]

  schema "triage_rules" do
    field :kind, :string
    field :name, :string
    field :enabled, :boolean, default: true
    field :subnet, Renga.Types.Inet
    field :hostname_pattern, :string
    field :label_key, :string
    field :label_value, :string
    # Which condition the rule uses, for the form only: "subnet" or
    # "intake_key" for network location, "hostname" or "label" for ownership.
    field :match_on, :string, virtual: true

    belongs_to :organization, Organization
    belongs_to :intake_api_key, Renga.Inventory.IntakeApiKey
    belongs_to :site, Renga.DCIM.Site
    belongs_to :location, Renga.DCIM.Location
    belongs_to :team, Renga.Teams.Team
    belongs_to :created_by_user, Renga.Accounts.User

    timestamps()
  end

  @doc "Rule kinds, in display order."
  def kinds, do: @kinds

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:kind, :name, :enabled, :match_on | @fields])
    |> update_change(:name, &trim/1)
    |> update_change(:hostname_pattern, &normalize_pattern/1)
    |> update_change(:label_key, &trim/1)
    |> validate_required([:organization_id, :kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 100)
    |> clear_unused_fields()
    |> validate_kind()
    |> unique_constraint(:name,
      name: :triage_rules_organization_name_index,
      message: "is already a rule in this organization"
    )
    |> assoc_constraint(:intake_api_key, name: :triage_rules_intake_api_key_fkey)
    |> assoc_constraint(:site, name: :triage_rules_site_fkey)
    |> assoc_constraint(:location, name: :triage_rules_location_fkey)
    |> assoc_constraint(:team, name: :triage_rules_team_fkey)
    |> check_constraint(:kind, name: :triage_rules_valid_shape, message: "is incomplete")
  end

  @doc "Turns a rule on or off without touching its conditions."
  def enabled_changeset(rule, enabled), do: change(rule, enabled: enabled)

  @doc "Which condition a rule uses, as the form's `match_on` names it."
  def match_on(%__MODULE__{kind: "ownership", label_key: key}) when not is_nil(key), do: "label"
  def match_on(%__MODULE__{kind: "ownership"}), do: "hostname"
  def match_on(%__MODULE__{intake_api_key_id: id}) when not is_nil(id), do: "intake_key"
  def match_on(%__MODULE__{}), do: "subnet"

  defp clear_unused_fields(changeset) do
    used = Map.get(@kind_fields, get_field(changeset, :kind), [])

    changeset =
      Enum.reduce(@fields -- used, changeset, fn field, changeset ->
        put_change(changeset, field, nil)
      end)

    # A rule matches on exactly one signal; the form picks which, so the
    # other one never lingers from an earlier choice.
    case {get_field(changeset, :kind), get_field(changeset, :match_on)} do
      {"network_location", "intake_key"} ->
        put_change(changeset, :subnet, nil)

      {"network_location", "subnet"} ->
        put_change(changeset, :intake_api_key_id, nil)

      {"ownership", "label"} ->
        put_change(changeset, :hostname_pattern, nil)

      {"ownership", "hostname"} ->
        changeset |> put_change(:label_key, nil) |> put_change(:label_value, nil)

      _other ->
        changeset
    end
  end

  defp validate_kind(changeset) do
    case get_field(changeset, :kind) do
      "network_location" -> validate_network_location(changeset)
      "ownership" -> validate_ownership(changeset)
      _top_of_rack_or_invalid -> changeset
    end
  end

  defp validate_network_location(changeset) do
    changeset = validate_required(changeset, [:site_id], message: "choose a site")

    case {get_field(changeset, :subnet), get_field(changeset, :intake_api_key_id)} do
      {nil, nil} ->
        if get_field(changeset, :match_on) == "intake_key",
          do: add_error(changeset, :intake_api_key_id, "choose an intake key"),
          else: add_error(changeset, :subnet, "enter a subnet such as 10.20.0.0/16")

      {%Postgrex.INET{netmask: nil}, _key} ->
        add_error(changeset, :subnet, "needs a prefix length, such as /24")

      {%Postgrex.INET{}, key} when is_binary(key) ->
        add_error(changeset, :subnet, "use a subnet or an intake key, not both")

      _one ->
        changeset
    end
  end

  defp validate_ownership(changeset) do
    changeset =
      changeset
      |> validate_required([:team_id], message: "choose a team")
      |> validate_length(:hostname_pattern, max: 100)
      |> validate_format(:hostname_pattern, @hostname_pattern,
        message: "use letters, digits, dots, dashes, underscores, and * only"
      )
      |> validate_length(:label_key, max: 63)
      |> validate_format(:label_key, @label_key, message: "is not a valid label key")
      |> validate_length(:label_value, max: 255)

    case {get_field(changeset, :hostname_pattern), get_field(changeset, :label_key)} do
      {nil, nil} ->
        if get_field(changeset, :match_on) == "label",
          do: add_error(changeset, :label_key, "enter the label key"),
          else: add_error(changeset, :hostname_pattern, "enter a hostname pattern such as web-*")

      {pattern, key} when is_binary(pattern) and is_binary(key) ->
        add_error(changeset, :hostname_pattern, "use a hostname pattern or a label, not both")

      {nil, _key} ->
        validate_required(changeset, [:label_value], message: "enter the label value")

      _pattern ->
        changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp normalize_pattern(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      pattern -> pattern
    end
  end

  defp normalize_pattern(value), do: value
end
