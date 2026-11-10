defmodule Renga.RequestLimits do
  @moduledoc """
  Cross-node, fixed-minute HTTP and LiveView limits for authenticated people.
  User limits apply within the selected organization; its aggregate limit
  also covers people using several sessions or nodes. Rejections spend neither
  counter. Each identity retains at most one row per traffic class.
  """

  alias Renga.Accounts.Scope
  alias Renga.Limits
  alias Renga.Repo

  @names %{
    http: {:http_organization_rate, :http_user_rate},
    live: {:live_organization_rate, :live_user_rate}
  }

  def check(scope, kind, now \\ System.system_time(:second))

  def check(%Scope{organization_id: organization_id, user: %{id: user_id}}, kind, now) do
    {organization_limit, user_limit} = Map.fetch!(@names, kind)

    limits =
      if organization_id,
        do:
          {Limits.get(organization_id, organization_limit),
           Limits.get(organization_id, user_limit)},
        else: {nil, Limits.default(user_limit)}

    window = div(now, 60)

    Repo.transaction(fn ->
      {organization_limit, user_limit} = limits
      # Every caller takes the aggregate first, so two sessions cannot
      # deadlock while acquiring the two counters in opposite orders.
      if organization_id, do: take!(organization_id, kind, nil, organization_limit, window, now)
      take!(organization_id, kind, user_id, user_limit, window, now)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, retry_after} -> {:error, retry_after}
    end
  end

  def check(_scope, _kind, _now), do: :ok

  defp take!(organization_id, kind, user_id, limit, window, now) do
    %{num_rows: rows} =
      Repo.query!(
        """
        INSERT INTO request_limit_windows (organization_id, key, kind, user_id, "window", count)
        SELECT $1, $2, $3, $4, $5, 1 WHERE $6::bigint > 0
        ON CONFLICT (key) DO UPDATE SET
          "window" = EXCLUDED."window",
          count = CASE WHEN request_limit_windows."window" = EXCLUDED."window"
            THEN request_limit_windows.count + 1 ELSE 1 END
        WHERE request_limit_windows."window" != EXCLUDED."window" OR request_limit_windows.count < $6
        """,
        [
          organization_id && Ecto.UUID.dump!(organization_id),
          "#{kind}:#{organization_id || "unscoped"}:#{user_id || "organization"}",
          Atom.to_string(kind),
          user_id && Ecto.UUID.dump!(user_id),
          window,
          limit
        ]
      )

    if rows == 0, do: Repo.rollback(60 - rem(now, 60))
  end

  @doc "Current aggregate usage, or the busiest user's usage, in this minute."
  def usage(organization_id, kind, user? \\ false) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COALESCE(max(count), 0) FROM request_limit_windows
        WHERE organization_id = $1 AND kind = $2 AND "window" = $3
          AND (user_id IS NOT NULL) = $4
        """,
        [
          Ecto.UUID.dump!(organization_id),
          Atom.to_string(kind),
          div(System.system_time(:second), 60),
          user?
        ]
      )

    count
  end
end
