defmodule RengaWeb.Operator.V1.OrganizationController do
  use RengaWeb, :controller
  use Oaskit.Controller

  alias Renga.DeploymentAudit
  alias Renga.Operators
  alias Renga.Operators.Idempotency
  alias Renga.Operators.Organizations
  alias RengaWeb.Operator.V1.Schemas

  tags ["Organizations"]

  # Bodies are small JSON objects. The endpoint parses none, so a malformed
  # one is refused here, after authentication, and recorded as an attempt.
  @max_body_bytes 16_384

  operation :create,
    operation_id: "createOrganization",
    summary: "Create an organization",
    description:
      "Creates an organization with no members; invite its owner next. Needs " <>
        "`organizations:write`.",
    parameters: ["idempotency-key": Schemas.idempotency_key_parameter()],
    request_body: Schemas.OrganizationCreate,
    responses:
      [
        created:
          Schemas.idempotent_response(Schemas.Organization, "The new organization."),
        unprocessable_entity:
          {Schemas.ValidationError, description: "The name or slug is invalid or taken."}
      ] ++ Schemas.write_responses()

  def create(conn, _params) do
    write(
      conn,
      "organization.create",
      201,
      &render_organization(%{organization: &1, members: []}),
      fn params, context, idempotency ->
        Organizations.create(params, context, idempotency)
      end
    )
  end

  operation :show,
    operation_id: "getOrganization",
    summary: "Read an organization",
    description:
      "Reads an organization's status and its active members' addresses and roles, so " <>
        "automation can confirm an owner joined. Needs `organizations:read`.",
    parameters: [id: [in: :path, required: true, schema: %{type: :string, format: :uuid}]],
    responses: [
      ok: {Schemas.Organization, description: "The organization."},
      unauthorized: Schemas.unauthorized_response(),
      forbidden: {Schemas.Error, description: "The token lacks `organizations:read`."},
      not_found: {Schemas.Error, description: "No organization has this ID."}
    ]

  def show(conn, %{"id" => id}) do
    with :ok <- authorize(conn, "organizations:read"),
         %{} = found <- Organizations.get(id) do
      json(conn, render_organization(found))
    else
      {:error, :forbidden} -> error(conn, 403, "forbidden")
      nil -> error(conn, 404, "not_found")
    end
  end

  operation :invite_owner,
    operation_id: "inviteOrganizationOwner",
    summary: "Invite an owner",
    description:
      "Emails `email` an invitation to own the organization, replacing any open " <>
        "invitation for the address. Accepting it requires signing in or registering with " <>
        "that confirmed address under the deployment's sign-in rules. The response never " <>
        "carries the invitation's link, and the invitation stops working if this token " <>
        "is revoked. Needs `organizations:write`.",
    parameters: [
      id: [in: :path, required: true, schema: %{type: :string, format: :uuid}],
      "idempotency-key": Schemas.idempotency_key_parameter()
    ],
    request_body: Schemas.OwnerInvitationCreate,
    responses:
      [
        created:
          Schemas.idempotent_response(
            Schemas.OwnerInvitation,
            "The invitation, already emailed."
          ),
        not_found: {Schemas.Error, description: "No active organization has this ID."},
        unprocessable_entity:
          {Schemas.ValidationError,
           description: "The address is invalid or already belongs to a member."},
        bad_gateway:
          {Schemas.Error,
           description:
             "The email could not be sent, so the invitation was not made. Retry with " <>
               "the same key."}
      ] ++ Schemas.write_responses()

  def invite_owner(conn, %{"id" => id}) do
    url_fun = &url(RengaWeb.Endpoint, ~p"/invitations/#{&1}")

    write(conn, "organization.invite_owner", 201, &render_invitation/1, fn params,
                                                                           context,
                                                                           idempotency ->
      Organizations.invite_owner(id, params["email"], context, url_fun, idempotency)
    end)
  end

  # Runs a non-idempotent write: checks the scope, the Idempotency-Key, and
  # the body, recording each refusal as an attempt, then returns a stored
  # response for a retry or runs `operation` and stores its response.
  defp write(conn, operation, status, render, run) do
    %{operator_token: token} = conn.assigns
    context = DeploymentAudit.token(token, request_id(conn))

    with :ok <- authorize(conn, "organizations:write"),
         {:ok, key} <- idempotency_key(conn),
         {:ok, params, conn} <- read_json(conn) do
      idempotency = %Idempotency{
        token_id: token.id,
        method: conn.method,
        route: route(conn),
        key: key,
        digest: Idempotency.digest(Map.put(params, "_path", conn.path_params)),
        status: status,
        render: render,
        expires_at: Idempotency.expiration()
      }

      case Idempotency.fetch(idempotency) do
        {:ok, stored} -> replay(conn, stored)
        {:error, :conflict} -> refuse(conn, context, operation, 409, :idempotency_key_reused)
        :none -> respond(conn, idempotency, run.(params, context, idempotency))
      end
    else
      {:error, :forbidden} -> refuse(conn, context, operation, 403, :forbidden)
      {:error, reason} -> refuse(conn, context, operation, 400, reason)
    end
  end

  defp respond(conn, idempotency, {:ok, result}) do
    conn
    |> put_idempotency_expiry(idempotency.expires_at)
    |> put_status(idempotency.status)
    |> json(idempotency.render.(result))
  end

  # A concurrent request with the same key finished first.
  defp respond(conn, idempotency, {:error, :replayed}) do
    case Idempotency.fetch(idempotency) do
      {:ok, stored} -> replay(conn, stored)
      {:error, :conflict} -> error(conn, 409, "idempotency_key_reused")
    end
  end

  defp respond(conn, _idempotency, {:error, %Ecto.Changeset{} = changeset}),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors(changeset)})

  defp respond(conn, _idempotency, {:error, :not_found}), do: error(conn, 404, "not_found")

  defp respond(conn, _idempotency, {:error, :delivery_failed}),
    do: error(conn, 502, "delivery_failed")

  defp authorize(conn, scope) do
    if Operators.authorized?(conn.assigns.operator_token, scope),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] ->
        if Idempotency.valid_key?(key), do: {:ok, key}, else: {:error, :invalid_idempotency_key}

      [] ->
        {:error, :idempotency_key_required}

      _several ->
        {:error, :invalid_idempotency_key}
    end
  end

  defp read_json(conn) do
    with {:ok, body, conn} <- read_body(conn, length: @max_body_bytes),
         {:ok, %{} = params} <- Jason.decode(body) do
      {:ok, params, conn}
    else
      _malformed_or_too_large -> {:error, :malformed_body}
    end
  end

  defp refuse(conn, context, operation, status, reason) do
    {:error, reason} = DeploymentAudit.reject(context, operation, reason)
    error(conn, status, Atom.to_string(reason))
  end

  defp replay(conn, {status, body, expires_at}) do
    conn
    |> put_resp_header("idempotent-replayed", "true")
    |> put_idempotency_expiry(expires_at)
    |> put_status(status)
    |> json(body)
  end

  defp put_idempotency_expiry(conn, expires_at) do
    put_resp_header(conn, "idempotency-key-expires-at", DateTime.to_iso8601(expires_at))
  end

  defp route(conn) do
    %{route: route} =
      Phoenix.Router.route_info(
        RengaWeb.OperatorRouter,
        conn.method,
        conn.request_path,
        conn.host
      )

    route
  end

  defp request_id(conn) do
    [request_id] = get_resp_header(conn, "x-request-id")
    request_id
  end

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp render_organization(%{organization: organization, members: members}) do
    %{
      id: organization.id,
      name: organization.name,
      slug: organization.slug,
      status: organization.status,
      members: Enum.map(members, &%{email: &1.email, role: &1.role})
    }
  end

  defp render_invitation(invitation) do
    %{
      id: invitation.id,
      organization_id: invitation.organization_id,
      email: invitation.email,
      role: invitation.role,
      expires_at: invitation.expires_at
    }
  end
end
