defmodule Renga.Release do
  @moduledoc """
  Tasks run from a built release, where Mix is not available.

  Deployments call `bin/migrate` (which runs `migrate/0`) before starting new
  application nodes, so schema changes land once rather than racing on boot.
  """

  @app :renga

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Reseals every stored secret under the current `ENCRYPTION_KEYS` key, so
  the operator can then remove an older key. Run it as `bin/reencrypt-secrets`
  after putting a new key first.
  """
  def reencrypt_secrets do
    load_app()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Renga.Repo, fn _repo ->
        Renga.Accounts.MFA.reencrypt_totp_secrets()
      end)

    case result do
      {:ok, count} ->
        IO.puts("Resealed #{count} authenticator secrets.")

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

    for repo <- repos() do
      {:ok, result, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Renga.Accounts.remove_mfa_by_operator(email, actor)
        end)

      case result do
        {:ok, _user} -> IO.puts("Removed the second factors of #{email}.")
        {:error, :not_found} -> raise "No account has the email #{email}."
      end
    end

    :ok
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
