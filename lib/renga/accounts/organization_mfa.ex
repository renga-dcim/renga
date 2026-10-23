defmodule Renga.Accounts.OrganizationMFA do
  @moduledoc """
  The current MFA admission policy for an organization (RFD 19).

  This check is shared by request-scope construction and transactional
  authorization so a newly enabled requirement cannot be bypassed by a
  scope cached in an already-connected LiveView.
  """

  alias Renga.Accounts.ProviderMFA
  alias Renga.Accounts.User
  alias Renga.SecuritySettings

  @doc "Whether `user`'s session may open `organization_id` now."
  def satisfied?(%User{} = user, organization_id) when is_binary(organization_id) do
    not SecuritySettings.require_mfa?(organization_id) or
      ProviderMFA.satisfies?(user.session_mfa, organization_id)
  end
end
