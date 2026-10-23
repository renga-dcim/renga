defmodule RengaWeb.OrganizationSessionController do
  use RengaWeb, :controller

  alias Renga.Accounts
  alias Renga.Accounts.Scope
  alias RengaWeb.UserAuth

  def create(conn, %{"organization" => %{"id" => organization_id}}) do
    conn = UserAuth.put_current_organization(conn, organization_id)

    case conn.assigns.current_scope do
      %{organization_id: ^organization_id} ->
        redirect(conn, to: ~p"/inbox")

      %{mfa_organization: %{id: ^organization_id}} ->
        redirect(conn, to: ~p"/organizations/confirm-mfa")

      _other ->
        conn
        |> put_flash(:error, "You do not have access to that organization.")
        |> redirect(to: ~p"/organizations")
    end
  end

  @doc """
  Confirms a passkey or authenticator code for this session, so the
  organization waiting for it opens (RFD 19). The session stays signed in
  whatever the outcome.
  """
  def confirm_mfa(conn, %{"confirm_mfa" => params}) do
    case conn.assigns.current_scope do
      %Scope{mfa_organization: %{}, user: user} ->
        result =
          Accounts.confirm_session_second_factor(
            user,
            get_session(conn, :user_token),
            credential(params)
          )

        case result do
          :ok ->
            redirect(conn, to: ~p"/inbox")

          {:error, :rate_limited} ->
            conn
            |> put_flash(:error, "Too many wrong codes. Try again later.")
            |> redirect(to: ~p"/organizations/confirm-mfa")

          {:error, _reason} ->
            conn
            |> put_flash(:error, "That didn't work. Try again.")
            |> redirect(to: ~p"/organizations/confirm-mfa")
        end

      %Scope{organization_id: organization_id} when is_binary(organization_id) ->
        redirect(conn, to: ~p"/inbox")

      _no_organization ->
        redirect(conn, to: ~p"/organizations")
    end
  end

  defp credential(%{"passkey" => response}) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, response} when is_map(response) -> {:passkey, response}
      _invalid -> :invalid
    end
  end

  defp credential(%{"code" => code}) when is_binary(code), do: code
  defp credential(_params), do: :invalid
end
