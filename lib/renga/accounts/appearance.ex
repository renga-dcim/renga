defmodule Renga.Accounts.Appearance do
  @moduledoc """
  How the UI looks for one person (RFD 8, "Visual design"): a theme
  (light, dark, or match the system), one of five accents, and a density.

  Preferences are stored on the user so they follow the person across
  devices. A person who has not chosen an accent sees their
  organization's default, which is Copper unless an owner changed it.
  The values map one-to-one to the `data-theme`, `data-accent`, and
  `data-density` attributes `assets/css/tokens.css` reads.
  """
  alias Renga.Accounts.Organization
  alias Renga.Accounts.Scope
  alias Renga.Accounts.User

  @themes ~w(system light dark)
  @accents ~w(copper petrol cobalt iris mono)
  @densities ~w(comfortable compact)
  @default_accent "copper"

  defstruct theme: "system", accent: @default_accent, density: "comfortable"

  def themes, do: @themes
  def accents, do: @accents
  def densities, do: @densities
  def default_accent, do: @default_accent

  @doc "The accent's name as people read it."
  def accent_label("mono"), do: "Monochrome"
  def accent_label(accent), do: String.capitalize(accent)

  @doc """
  The appearance a scope renders with: the user's own choices, falling
  back to the organization's default accent. Without a user, the
  defaults (the browser's own theme choice still applies).
  """
  def for_scope(%Scope{user: %User{} = user, organization: organization}) do
    %__MODULE__{
      theme: user.theme || "system",
      accent: user.accent || organization_accent(organization),
      density: user.density || "comfortable"
    }
  end

  def for_scope(_scope), do: %__MODULE__{}

  defp organization_accent(%Organization{default_accent: accent}) when accent in @accents,
    do: accent

  defp organization_accent(_organization), do: @default_accent
end
