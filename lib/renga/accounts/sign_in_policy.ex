defmodule Renga.Accounts.SignInPolicy do
  @moduledoc """
  The deployment's local sign-in policy (RFD 15, "Local sign-in policy"):
  whether passwords and magic links work alongside identity providers.
  """

  @doc "Whether local credentials (passwords and magic links) can sign in."
  def local_sign_in? do
    Application.get_env(:renga, :local_sign_in, :enabled) == :enabled
  end
end
