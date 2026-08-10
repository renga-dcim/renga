defmodule RengaWeb.Api.V1.AgentCredentialController do
  use RengaWeb, :controller

  alias Renga.Enrollment

  def renew(%{assigns: %{agent_auth_kind: :credential}} = conn, _params) do
    case Enrollment.renew_agent_credential(
           conn.assigns.current_scope,
           conn.assigns.current_source,
           conn.assigns.current_agent,
           conn.assigns.current_agent_credential
         ) do
      {:ok, credential} ->
        json(conn, %{
          credential_id: Base.url_encode64(credential.credential_id, padding: false),
          expires_at: DateTime.to_iso8601(credential.expires_at)
        })

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: [%{path: "authorization", message: "is invalid"}]})
    end
  end
end
