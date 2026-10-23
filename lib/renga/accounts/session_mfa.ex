defmodule Renga.Accounts.SessionMFA do
  @moduledoc """
  What a session's sign-in proved about a second factor (RFD 19, "MFA
  requirement"), as recorded on its session token.

  It is evidence, not a verdict. Renga's own second factor (a passkey, or a
  password or emailed link followed by the second step) counts wherever MFA
  is required. A provider sign-in only records which provider it was, who
  owns it, and the ID token's `amr` claim, so each organization evaluates
  that evidence for itself when it is opened, against the provider's mark
  as it stands then.
  """

  defstruct second_factor_at: nil,
            provider_id: nil,
            provider_organization_id: nil,
            provider_amr: nil

  @type t :: %__MODULE__{
          second_factor_at: DateTime.t() | nil,
          provider_id: String.t() | nil,
          provider_organization_id: Ecto.UUID.t() | nil,
          provider_amr: [String.t()] | nil
        }

  # Sign-in methods that are Renga's own second factor: a passkey alone is
  # two factors because Renga requires user verification, and the others are
  # the second step after a password or emailed link.
  @second_factor_methods ~w(passkey totp recovery_code)

  @doc """
  The evidence a local sign-in by `method` leaves, such as `"passkey"` or
  `:totp`. A password or emailed link alone leaves none.
  """
  def for_method(method) when is_atom(method) and not is_nil(method),
    do: for_method(Atom.to_string(method))

  def for_method(method) when method in @second_factor_methods,
    do: %__MODULE__{second_factor_at: Renga.Time.utc_now_ms()}

  def for_method(_method), do: %__MODULE__{}

  @doc """
  The evidence a sign-in through `provider` leaves. `amr` is kept only when
  the ID token carried it as a list of strings; any other shape is kept as
  an empty list, which proves no factor, rather than as absent, which would
  let the provider's mark decide alone.
  """
  def for_provider(%{id: provider_id, organization_id: organization_id}, claims)
      when is_map(claims) do
    %__MODULE__{
      provider_id: provider_id,
      provider_organization_id: organization_id,
      provider_amr: amr(claims)
    }
  end

  defp amr(%{"amr" => amr}) when is_list(amr) do
    if Enum.all?(amr, &is_binary/1), do: amr, else: []
  end

  defp amr(%{"amr" => _malformed}), do: []
  defp amr(_claims), do: nil

  @doc "Whether the session passed Renga's own second factor."
  def second_factor?(%__MODULE__{second_factor_at: %DateTime{}}), do: true
  def second_factor?(_evidence), do: false

  @doc "The session token fields that record `evidence`."
  def token_fields(nil), do: token_fields(%__MODULE__{})

  def token_fields(%__MODULE__{} = evidence) do
    [
      second_factor_at: evidence.second_factor_at,
      provider_id: evidence.provider_id,
      provider_organization_id: evidence.provider_organization_id,
      provider_amr: evidence.provider_amr
    ]
  end
end
