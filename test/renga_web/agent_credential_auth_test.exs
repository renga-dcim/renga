defmodule RengaWeb.AgentCredentialAuthTest do
  use ExUnit.Case, async: true

  alias RengaWeb.AgentCredentialAuth

  test "transcript is deterministic and binds every request component" do
    values = %{
      credential_id_encoded: Base.url_encode64(:binary.copy(<<1>>, 32), padding: false),
      installation_id: "4d09dbd3-768b-4ad8-8c35-d094a38e95b7",
      method: "post",
      request_target: "/api/v1/key/observations?sequence=1",
      content_type: "application/json;charset=utf-8",
      timestamp: 1_786_310_400,
      nonce_encoded: Base.url_encode64(:binary.copy(<<2>>, 32), padding: false),
      body_digest: :crypto.hash(:sha256, ~s({"value":1}))
    }

    transcript = AgentCredentialAuth.transcript(values)
    assert transcript == AgentCredentialAuth.transcript(values)

    for {field, replacement} <- [
          method: "PUT",
          request_target: "/api/v1/key/observations?sequence=2",
          content_type: "application/json",
          timestamp: values.timestamp + 1,
          nonce_encoded: Base.url_encode64(:binary.copy(<<3>>, 32), padding: false),
          body_digest: :crypto.hash(:sha256, ~s({"value":2}))
        ] do
      refute transcript == AgentCredentialAuth.transcript(Map.put(values, field, replacement))
    end
  end
end
