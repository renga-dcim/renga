defmodule Renga.Release do
  @moduledoc """
  Tasks run from a built release, where Mix is not available.

  Deployments call `bin/migrate` (which runs `migrate/0`) before starting new
  application nodes, so schema changes land once rather than racing on boot.
  """

  alias Renga.Release.Providers

  @app :renga

  def migrate do
    load_app()
    without_statement_timeout()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    without_statement_timeout()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Reseals authenticator secrets and identity provider client secrets under
  the current `ENCRYPTION_KEYS` key. Run it as `bin/reencrypt-secrets` after
  putting a new key first. Pending operator invitation links are short-lived
  and are not resealed, so keep their old keys configured until those emails
  have been delivered before removing an older key.
  """
  def reencrypt_secrets do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Renga.Repo, fn _repo ->
        with {:ok, totp} <- Renga.Accounts.MFA.reencrypt_totp_secrets(),
             {:ok, providers} <-
               Renga.Accounts.IdentityProviders.reencrypt_secrets(
                 {:operator, "bin/reencrypt-secrets"}
               ) do
          {:ok, totp, providers}
        end
      end)

    case result do
      {:ok, totp, providers} ->
        IO.puts(
          "Resealed #{totp} authenticator secrets and #{providers} identity provider secrets."
        )

      {:error, reason} ->
        IO.puts(:stderr, "Could not reseal secrets: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Removes every second factor from an account whose owner lost them all
  and has no recovery code left (RFD 19, "Recovery"). `actor` names whoever
  ran it in the account's security log. Organization owners cannot do this,
  because they do not control the person's other organizations.

      bin/remove-mfa person@example.com "Jane (ticket 1234)"
  """
  def remove_mfa(email, actor) do
    load_app()
    # The notice to the account goes out from here, so the mailer's HTTP
    # client must run too.
    {:ok, _apps} = Application.ensure_all_started([:swoosh, :req])

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Renga.Accounts.remove_mfa_by_operator(email, actor)
        end)

      case result do
        {:ok, _user, :ok} ->
          IO.puts("Removed the second factors of #{email} and emailed a notice.")

        {:ok, _user, {:error, reason}} ->
          IO.puts("Removed the second factors of #{email}.")
          IO.puts(:stderr, "The notice could not be emailed: #{inspect(reason)}")

        {:error, :not_found} ->
          raise "No account has the email #{email}."
      end
    end

    :ok
  end

  @doc """
  Runs `bin/providers` (`Renga.Release.Providers`) with the arguments the
  script passes in `RENGA_ARGV`, one per line. Exits non-zero on failure.
  """
  def providers do
    load_app()

    argv =
      "RENGA_ARGV"
      |> System.get_env("")
      |> String.split("\n", trim: true)
      |> Enum.map(fn "x" <> argument -> argument end)

    [repo | _] = repos()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(repo, fn _repo -> Providers.run(argv) end)

    case result do
      {:ok, output} ->
        IO.puts(output)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  # Migrations may rewrite large tables, so they run without the baseline
  # statement timeout that bounds application queries (RFD 21). This only
  # changes the configuration of the migrating VM's own repos, which
  # `bin/migrate` starts fresh with `eval`; it would not reach a pool that
  # is already running.
  defp without_statement_timeout do
    for repo <- repos() do
      config = Application.get_env(@app, repo, [])
      parameters = config |> Keyword.get(:parameters, []) |> Keyword.put(:statement_timeout, "0")
      Application.put_env(@app, repo, Keyword.put(config, :parameters, parameters))
    end
  end

  @doc """
  Runs `fun` with the repositories started but not the rest of the
  application, for release commands such as `bin/renga-admin`, and returns
  its result.
  """
  def with_repos(fun) do
    load_app()

    Enum.reduce(repos(), fun, fn repo, inner ->
      fn ->
        {:ok, result, _apps} = Ecto.Migrator.with_repo(repo, fn _repo -> inner.() end)
        result
      end
    end).()
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Releases start without SSL loaded, but runtime.exs may ask the repo for
    # a verified TLS connection.
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
