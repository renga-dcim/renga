defmodule RengaWeb.Scim.RateLimit do
  @moduledoc """
  Limits each SCIM connection to a number of requests a minute (RFD 16,
  "Endpoints"), so one provider's burst or a leaked token cannot crowd out
  the rest of the deployment. A request over the limit gets a `429` with
  `Retry-After`.

  Counts are kept per node in fixed one-minute windows, so a deployment of
  several nodes admits up to that many times the limit. Configure it with
  `config :renga, #{inspect(__MODULE__)}, requests_per_minute: n`.
  """

  @behaviour Plug

  import Plug.Conn

  alias RengaWeb.Scim.Response

  @table __MODULE__.Table
  @default_per_minute 600

  @doc "The configured limit."
  def requests_per_minute do
    :renga
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:requests_per_minute, @default_per_minute)
  end

  @doc """
  Counts a request for `key` against `limit`. Returns `:ok`, or
  `{:error, retry_after}` with the seconds until the window ends.
  """
  def check(key, limit, now \\ System.system_time(:second)) do
    window = div(now, 60)
    count = :ets.update_counter(@table, {key, window}, 1, {{key, window}, 0})

    if count <= limit, do: :ok, else: {:error, 60 - rem(now, 60)}
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{scim_connection: connection}} = conn, _opts) do
    case check(connection.id, requests_per_minute()) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> Response.error(429, "Too many requests for this connection; retry later")
        |> halt()
    end
  end

  defmodule Table do
    @moduledoc "Owns the rate limit counters and drops windows that have ended."

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
      schedule_sweep()
      {:ok, nil}
    end

    @impl true
    def handle_info(:sweep, state) do
      current = div(System.system_time(:second), 60)
      :ets.select_delete(__MODULE__, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
      schedule_sweep()
      {:noreply, state}
    end

    defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(1))
  end
end
