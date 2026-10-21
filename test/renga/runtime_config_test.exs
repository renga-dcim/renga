defmodule Renga.RuntimeConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @secret String.duplicate("s", 64)

  setup do
    previous_repo_config = Application.fetch_env!(:renga, Renga.Repo)

    on_exit(fn -> Application.put_env(:renga, Renga.Repo, previous_repo_config) end)
  end

  test "DATABASE_SSL keeps verified TLS after Ecto resolves the database URL" do
    for query <- [nil, "ssl=true", "ssl=true&ssl=true"] do
      {repo_config, log} =
        with_log(fn -> query |> database_url() |> resolved_repo_config() end)

      ssl = Keyword.fetch!(repo_config, :ssl)

      assert ssl[:verify] == :verify_peer
      assert ssl[:server_name_indication] == ~c"database.example.com"
      assert is_list(ssl[:cacerts])
      assert is_function(ssl[:customize_hostname_check][:match_fun], 2)

      if query do
        assert log =~ "ignoring `ssl=true` parameter"
      else
        assert log == ""
      end
    end
  end

  test "DATABASE_SSL rejects URL options that would disable verified TLS" do
    for query <- ["ssl=false", "ssl=true&ssl=false", "ssl=false&ssl=true"] do
      assert_raise RuntimeError, ~r/DATABASE_SSL=true cannot be combined/, fn ->
        query
        |> database_url()
        |> read_runtime_config()
      end
    end
  end

  test "application connections get a baseline statement timeout" do
    repo_config = fn environment ->
      config =
        with_env(
          Map.merge(
            %{
              "DATABASE_URL" => database_url(nil),
              "SECRET_KEY_BASE" => @secret,
              "PHX_HOST" => "renga.example.com"
            },
            environment
          ),
          fn -> Config.Reader.read!(@runtime_config, env: :prod) end
        )

      {config |> Keyword.fetch!(:renga) |> Keyword.fetch!(Renga.Repo),
       config |> Keyword.fetch!(:renga) |> Keyword.fetch!(:background_statement_timeout_ms)}
    end

    {repo, background} = repo_config.(%{})
    assert repo[:parameters][:statement_timeout] == "30000ms"
    assert background == 300_000

    {repo, background} =
      repo_config.(%{
        "DATABASE_STATEMENT_TIMEOUT" => "5000",
        "DATABASE_BACKGROUND_STATEMENT_TIMEOUT" => "60000"
      })

    assert repo[:parameters][:statement_timeout] == "5000ms"
    assert background == 60_000
  end

  defp resolved_repo_config(database_url) do
    config = read_runtime_config(database_url)
    repo_config = config |> Keyword.fetch!(:renga) |> Keyword.fetch!(Renga.Repo)
    Application.put_env(:renga, Renga.Repo, repo_config)
    Renga.Repo.config()
  end

  defp read_runtime_config(database_url) do
    with_env(
      %{
        "DATABASE_SSL" => "true",
        "DATABASE_URL" => database_url,
        "SECRET_KEY_BASE" => @secret,
        "PHX_HOST" => "renga.example.com"
      },
      fn -> Config.Reader.read!(@runtime_config, env: :prod) end
    )
  end

  defp database_url(nil), do: "ecto://user:password@database.example.com/renga"

  defp database_url(query) do
    "ecto://user:password@database.example.com/renga?#{query}"
  end

  defp with_env(environment, fun) do
    previous = Map.new(environment, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(environment)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
