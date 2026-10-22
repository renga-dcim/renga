defmodule Renga.Accounts.ProviderMFA do
  @moduledoc """
  When a sign-in through an identity provider counts as multi-factor (RFD
  19, "MFA requirement").

  A provider counts only when it carries the _enforces MFA_ mark: the
  operator sets it on deployment providers, and an organization's owners
  on that organization's own providers. A `github` provider never carries
  it, because GitHub's OAuth API says nothing about how the person signed
  in. An organization provider's mark counts only for its owning
  organization.

  The ID token's `amr` claim (RFC 8176) can only take away from the mark:
  when present it must contain `mfa`, or every method of a combination the
  provider's configuration approves. Counting methods is not enough, so a
  combination is approved only when its methods span at least two of
  knowledge, possession, and inherence; `pwd` and `kba` are both knowledge.
  """

  import Ecto.Query

  alias Renga.Accounts.IdentityProvider
  alias Renga.Accounts.SessionMFA
  alias Renga.Repo

  # RFC 8176's registered methods by the factor each proves. The remaining
  # registered values (geo, mca, rba, user, wia) prove no factor of their own.
  @factors %{
    "pwd" => :knowledge,
    "pin" => :knowledge,
    "kba" => :knowledge,
    "hwk" => :possession,
    "swk" => :possession,
    "otp" => :possession,
    "sms" => :possession,
    "tel" => :possession,
    "sc" => :possession,
    "fpt" => :inherence,
    "face" => :inherence,
    "iris" => :inherence,
    "retina" => :inherence,
    "vbm" => :inherence
  }
  @other_methods ~w(geo mca rba user wia)

  @doc """
  Whether a session with `evidence` may open `organization_id` under its
  MFA requirement: Renga's own second factor passed, or the sign-in went
  through a marked provider whose mark counts for that organization and
  whose `amr`, if any, agrees. The provider is read as it stands now, so
  removing a mark applies at the member's next request.
  """
  def satisfies?(%SessionMFA{} = evidence, organization_id) when is_binary(organization_id) do
    SessionMFA.second_factor?(evidence) or provider_satisfies?(evidence, organization_id)
  end

  def satisfies?(_evidence, _organization_id), do: false

  defp provider_satisfies?(%SessionMFA{provider_id: nil}, _organization_id), do: false

  defp provider_satisfies?(%SessionMFA{} = evidence, organization_id) do
    provider =
      Repo.one(
        from p in IdentityProvider,
          where: p.id == ^evidence.provider_id and is_nil(p.removed_at)
      )

    case provider do
      %IdentityProvider{kind: kind, enforces_mfa: true} = provider when kind != "github" ->
        # The evidence names the owner the provider had at sign-in; an owner
        # never changes, so a mismatch means the evidence is not this one's.
        provider.organization_id == evidence.provider_organization_id and
          provider.organization_id in [nil, organization_id] and
          amr_agrees?(evidence.provider_amr, provider.mfa_amr_combinations)

      _unmarked_or_gone ->
        false
    end
  end

  @doc """
  Whether an ID token's `amr` (nil when the token had none) agrees with a
  marked provider: absent, it leaves the mark to decide; present, it must
  hold `mfa` or every method of one approved combination.
  """
  def amr_agrees?(nil, _combinations), do: true

  def amr_agrees?(amr, combinations) when is_list(amr) do
    methods = MapSet.new(amr)

    "mfa" in methods or
      Enum.any?(combinations, fn combination ->
        combination |> split() |> MapSet.new() |> MapSet.subset?(methods)
      end)
  end

  @doc """
  Normalizes an approved combination such as `"pwd + otp"` to `"otp+pwd"`,
  or explains why it cannot be approved.
  """
  def normalize_combination(combination) when is_binary(combination) do
    methods = combination |> split() |> Enum.uniq() |> Enum.sort()
    unknown = Enum.reject(methods, &(Map.has_key?(@factors, &1) or &1 in @other_methods))
    factors = methods |> Enum.map(&@factors[&1]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cond do
      unknown != [] ->
        {:error, "#{Enum.join(unknown, ", ")} is not an RFC 8176 method"}

      length(factors) < 2 ->
        {:error, "#{Enum.join(methods, "+")} does not combine two independent factors"}

      true ->
        {:ok, Enum.join(methods, "+")}
    end
  end

  defp split(combination) do
    combination
    |> String.split("+")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end
end
