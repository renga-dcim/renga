defmodule RengaWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use RengaWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Oaskit.Validation.RequestData
  alias Oaskit.Validation.RequestValidator

  using do
    quote do
      # The default endpoint for testing
      @endpoint RengaWeb.Endpoint

      use RengaWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import RengaWeb.ConnCase
    end
  end

  setup tags do
    Renga.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Asserts the response status, checks the body against the operation's
  documented response in `RengaWeb.ApiSpec`, and returns the decoded body.

  Use it for every machine API response, so the published spec cannot drift
  from what the controllers send. Pass the operation ID when a test calls a
  controller action directly, since there is then no route to look it up by.
  """
  def valid_api_response(conn, status, operation_id \\ nil) do
    operation_id = operation_id || api_operation_id!(conn)
    if status in 200..299, do: assert_documented_request!(conn, operation_id)

    conn
    |> Plug.Conn.put_private(:oaskit, %{operation_id: operation_id})
    |> then(&Oaskit.Test.valid_response(RengaWeb.ApiSpec, &1, status))
  end

  # A request the API accepted must also satisfy its documented schema, or the
  # spec is stricter than the API and would mislead client authors. Tests post
  # some bodies as maps rather than JSON, so the content type is normalized.
  defp assert_documented_request!(conn, operation_id) do
    request =
      conn
      |> RequestData.from_conn()
      |> Map.update!(:req_headers, fn headers ->
        [{"content-type", "application/json"} | List.keydelete(headers, "content-type", 0)]
      end)

    case RequestValidator.validate_request(request, RengaWeb.ApiSpec, operation_id) do
      {:ok, _cast} ->
        :ok

      {:error, error} ->
        raise ExUnit.AssertionError,
          message:
            "the API accepted a request that operation #{inspect(operation_id)} documents " <>
              "as invalid:\n\n#{if is_exception(error), do: Exception.message(error), else: inspect(error)}"
    end
  end

  # Requests skip Oaskit's validation plug, which would otherwise record the
  # operation, because `Renga.Inventory.AgentPayload` validates them. Find the
  # operation the spec documents for the route instead.
  defp api_operation_id!(conn) do
    %{route: route} =
      Phoenix.Router.route_info(RengaWeb.Router, conn.method, conn.request_path, conn.host)

    key = {String.downcase(conn.method), String.replace(route, ~r/:(\w+)/, "{\\1}")}

    case api_operations() do
      %{^key => operation_id} ->
        operation_id

      _undocumented ->
        raise ExUnit.AssertionError,
          message: "#{conn.method} #{route} has no operation in RengaWeb.ApiSpec"
    end
  end

  defp api_operations do
    with :none <- :persistent_term.get({__MODULE__, :api_operations}, :none) do
      %{"paths" => paths} =
        Oaskit.normalize_spec!(RengaWeb.ApiSpec.spec(), spec_module: RengaWeb.ApiSpec)

      operations =
        for {path, methods} <- paths,
            {method, %{"operationId" => operation_id}} <- methods,
            into: %{},
            do: {{method, path}, operation_id}

      :persistent_term.put({__MODULE__, :api_operations}, operations)
      operations
    end
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = Renga.AccountsFixtures.user_fixture()
    scope = Renga.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`. `:mfa` is the session's
  `Renga.Accounts.SessionMFA` evidence, none by default.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = Renga.Accounts.generate_user_session_token(user, nil, nil, opts[:mfa])

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    Renga.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
