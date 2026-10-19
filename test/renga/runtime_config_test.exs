defmodule Renga.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @secret String.duplicate("s", 64)

  setup do
    previous_repo_config = Application.fetch_env!(:renga, Renga.Repo)

    on_exit(fn -> Application.put_env(:renga, Renga.Repo, previous_repo_config) end)
  end

  test "DATABASE_SSL keeps verified TLS after Ecto resolves the database URL" do
    for query <- [nil, "ssl=true", "ssl=true&ssl=true"] do
      ssl =
        query
        |> database_url()
        |> resolved_repo_config()
        |> Keyword.fetch!(:ssl)

      assert ssl[:verify] == :verify_peer
      assert ssl[:server_name_indication] == ~c"database.example.com"
      assert is_list(ssl[:cacerts])
      assert is_function(ssl[:customize_hostname_check][:match_fun], 2)
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
