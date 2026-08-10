# credo:disable-for-this-file Credo.Check.Refactor.CyclomaticComplexity
defmodule Renga.Enrollment.JWKSCache do
  @moduledoc "Bounded last-known-good JWKS cache with serialized refreshes."

  use GenServer

  @table __MODULE__
  @fresh_seconds 60
  @forced_refresh_seconds 10
  @max_body_bytes 262_144

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  def get(config, validator, force_refresh \\ false) when is_function(validator, 1) do
    url = Map.fetch!(config, "jwks_url")
    cached = lookup(url)

    if not force_refresh and fresh?(cached) do
      {:ok, cached.keys, cached.fetched_at}
    else
      :global.trans({__MODULE__, url}, fn -> refresh(config, cached, validator, force_refresh) end)
    end
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp refresh(config, previous, validator, force_refresh) do
    current = lookup(config["jwks_url"])

    cond do
      not force_refresh and fresh?(current) ->
        {:ok, current.keys, current.fetched_at}

      (force_refresh and current) && previous && current.fetched_at > previous.fetched_at ->
        {:ok, current.keys, current.fetched_at}

      force_refresh and recent_forced_refresh(config["jwks_url"]) == :ok ->
        {:ok, current.keys, current.fetched_at}

      force_refresh and recent_forced_refresh(config["jwks_url"]) == :error ->
        {:error, :unavailable}

      true ->
        fetch_or_fallback(config, current, validator, force_refresh)
    end
  end

  defp fetch_or_fallback(config, cached, validator, force_refresh) do
    collector = fn {:data, chunk}, {request, response} ->
      body = [response.body || [], chunk]

      if IO.iodata_length(body) > @max_body_bytes,
        do: {:halt, {request, %{response | body: :too_large}}},
        else: {:cont, {request, %{response | body: body}}}
    end

    options =
      [
        url: config["jwks_url"],
        method: :get,
        redirect: false,
        retry: false,
        raw: true,
        compressed: false,
        receive_timeout: min(config["http_timeout_ms"] || 2_000, 5_000),
        connect_options: [timeout: min(config["http_timeout_ms"] || 2_000, 5_000)],
        into: collector
      ] ++ Application.get_env(:renga, :oidc_req_options, [])

    case Req.request(options) do
      {:ok, %{status: 200, body: body}} when body != :too_large ->
        store_response(config, IO.iodata_to_binary(body), cached, validator, force_refresh)

      _ ->
        failed_refresh(config, cached, force_refresh)
    end
  rescue
    _ -> failed_refresh(config, cached, force_refresh)
  end

  defp store_response(config, body, cached, validator, force_refresh) do
    with {:ok, %{"keys" => keys}} <- Jason.decode(body),
         {:ok, sanitized_keys} <- validator.(keys) do
      now = System.monotonic_time(:second)
      :ets.insert(@table, {config["jwks_url"], sanitized_keys, now})
      record_forced_refresh(config["jwks_url"], force_refresh, :ok)
      {:ok, sanitized_keys, now}
    else
      _ -> failed_refresh(config, cached, force_refresh)
    end
  end

  defp failed_refresh(config, _cached, true) do
    record_forced_refresh(config["jwks_url"], true, :error)
    {:error, :unavailable}
  end

  defp failed_refresh(config, cached, false), do: stale_fallback(config, cached)

  defp recent_forced_refresh(url) do
    case :ets.lookup(@table, {:forced_refresh, url}) do
      [{{:forced_refresh, ^url}, at, status}]
      when is_integer(at) and is_atom(status) ->
        if System.monotonic_time(:second) - at <= @forced_refresh_seconds, do: status

      _ ->
        nil
    end
  end

  defp record_forced_refresh(_url, false, _status), do: :ok

  defp record_forced_refresh(url, true, status),
    do: :ets.insert(@table, {{:forced_refresh, url}, System.monotonic_time(:second), status})

  defp stale_fallback(config, %{keys: keys, fetched_at: fetched_at}) do
    age = System.monotonic_time(:second) - fetched_at

    if age <= config["max_jwks_staleness_seconds"],
      do: {:ok, keys, fetched_at},
      else: {:error, :unavailable}
  end

  defp stale_fallback(_config, _cached), do: {:error, :unavailable}

  defp lookup(url) do
    case :ets.lookup(@table, url) do
      [{^url, keys, fetched_at}] -> %{keys: keys, fetched_at: fetched_at}
      [] -> nil
    end
  end

  defp fresh?(%{fetched_at: fetched_at}),
    do: System.monotonic_time(:second) - fetched_at <= @fresh_seconds

  defp fresh?(_), do: false
end
