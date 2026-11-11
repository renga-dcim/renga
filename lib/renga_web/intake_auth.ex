defmodule RengaWeb.IntakeAuth do
  @moduledoc """
  Authenticates organization intake keys for the agent JSON API and the
  agent socket.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Renga.Accounts
  alias Renga.Accounts.Organization
  alias Renga.Inventory
  alias Renga.Inventory.IntakeApiKey
  alias Renga.IntakeCapacity

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, scope, installation_id, key} <-
           authenticate(token, get_req_header(conn, "x-renga-installation-id"), lane(conn)) do
      conn
      |> assign(:current_scope, scope)
      |> assign(:current_installation_id, installation_id)
      |> assign(:current_intake_api_key, key)
      |> measure(scope.organization_id)
      |> admit(scope.organization_id, installation_id)
    else
      {:error, :capacity} ->
        throttled(conn, 1)

      {:error, :organization_suspended} ->
        conn
        |> put_status(:forbidden)
        |> json(%{status: "rejected", errors: [%{path: "organization", message: "is suspended"}]})
        |> halt()

      _invalid ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: [%{path: "authorization", message: "is invalid or missing"}]})
        |> halt()
    end
  end

  @doc """
  Checks an intake key and the installation ID an agent claims, given as the
  values of its `x-renga-installation-id` header, and records the contact.
  Every agent entry point authenticates through here, so they agree on what
  a valid caller is.
  """
  def authenticate(token, installation_header),
    do: authenticate(token, installation_header, :bulk)

  defp authenticate(token, installation_header, lane) when is_binary(token) do
    IntakeCapacity.authentication(
      fn -> authenticate_credential(token, installation_header) end,
      lane
    )
  end

  defp authenticate(_token, _installation_header, _lane), do: :error

  defp authenticate_credential(token, installation_header) do
    with {:ok, installation_id} <- installation_id(installation_header),
         {:ok, %IntakeApiKey{organization: %Organization{} = organization} = key} <-
           Inventory.authenticate_intake_api_key(token) do
      # Before the payload is judged, so a rejected report still counts.
      :ok = IntakeCapacity.contact(key, installation_id)

      if organization.status == "active" do
        {:ok, Accounts.scope_for(organization), installation_id, key}
      else
        {:error, :organization_suspended}
      end
    else
      {:error, :organization_suspended} -> {:error, :organization_suspended}
      _invalid -> :error
    end
  end

  defp measure(conn, organization_id) do
    started = System.monotonic_time()
    previous = Process.put(:intake_organization_id, organization_id)

    register_before_send(conn, fn conn ->
      Process.put(:intake_organization_id, previous)

      :telemetry.execute(
        [:renga, :intake, :request],
        %{
          count: 1,
          bytes: Map.get(conn.private, :intake_bytes, 0),
          duration: System.monotonic_time() - started
        },
        %{organization_id: organization_id, status: conn.status, lane: lane(conn)}
      )

      conn
    end)
  end

  defp admit(conn, organization_id, installation_id) do
    # The admission permit spans both acceptance and inline reconciliation,
    # not just their individual database transactions.
    result =
      IntakeCapacity.authentication(
        fn ->
          IntakeCapacity.admit(
            organization_id,
            installation_id,
            admission_class(conn),
            IntakeCapacity.limits(organization_id)
          )
        end,
        lane(conn)
      )

    case result do
      {:ok, ref} ->
        register_before_send(conn, fn conn ->
          IntakeCapacity.release(ref)
          conn
        end)

      {:error, retry_after} when is_integer(retry_after) ->
        throttled(conn, retry_after)

      {:error, :capacity} ->
        throttled(conn, 1)
    end
  end

  defp lane(%{path_info: ["api", "v1", "agent", "checkins"]}), do: :maintenance
  defp lane(%{path_info: ["api", "v1", "agent", "jobs", _id, "events"]}), do: :maintenance
  defp lane(_conn), do: :bulk

  defp admission_class(%{path_info: ["api", "v1", "agent", "jobs", "lease"]}), do: :lease
  defp admission_class(%{path_info: ["api", "v1", "agent", "jobs", _id, "claims"]}), do: :lease
  defp admission_class(conn), do: lane(conn)

  defp throttled(conn, seconds) do
    :telemetry.execute([:renga, :intake, :rejected], %{count: 1}, %{
      organization_id: conn.assigns[:current_scope] && conn.assigns.current_scope.organization_id
    })

    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(:too_many_requests)
    |> json(%{status: "rejected", errors: [%{path: "capacity", message: "retry later"}]})
    |> halt()
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing_or_invalid -> :error
    end
  end

  defp installation_id([installation_id]), do: Ecto.UUID.cast(installation_id)
  defp installation_id(_missing_or_repeated), do: :error
end
