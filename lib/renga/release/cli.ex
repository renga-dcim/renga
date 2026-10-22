defmodule Renga.Release.CLI do
  @moduledoc """
  The `renga-admin` release command: operator tasks run on the server.

  It reaches the same domain functions as the operator API (RFD 22), so a
  deployment without network access to that API can be run the same way.
  `bin/renga-admin` calls `main/1` from a built release, and
  `mix renga.admin` does in development.
  """

  alias Renga.Accounts
  alias Renga.DeploymentAudit
  alias Renga.Limits
  alias Renga.Operators

  @usage """
  Usage:
    renga-admin operator-tokens create --actor NAME --name NAME --scopes SCOPE[,SCOPE...]
                                       [--expires-at ISO8601] [--source CIDR...]
    renga-admin operator-tokens list
    renga-admin operator-tokens revoke ID_OR_NAME --actor NAME
    renga-admin limits show --organization SLUG
    renga-admin limits set --organization SLUG --actor NAME --LIMIT VALUE [--LIMIT VALUE...]
    renga-admin limits clear --organization SLUG --actor NAME --limit LIMIT

  Changes need --actor, the person making them, which the deployment audit
  log records with an invocation ID. --scope SCOPE may also be repeated.

  Limits: #{Enum.map_join(Renga.Limits.names(), ", ", &String.replace(Atom.to_string(&1), "_", "-"))}
  """

  @doc """
  Runs a command and returns its exit status. Output goes to stdout, errors to
  stderr.
  """
  def run(argv)

  def run(["operator-tokens", "create" | args]) do
    switches = [name: :string, scope: :keep, scopes: :keep, expires_at: :string, source: :keep]

    with {:ok, context, opts, rest, invalid} <- parse_change(args, switches),
         :ok <- audited(context, "operator_token.create", no_extra_args(rest, invalid)),
         {:ok, attrs} <- audited(context, "operator_token.create", token_attrs(opts)) do
      case Operators.create_token(attrs, context) do
        {:ok, {token, plaintext}} ->
          IO.puts("Created operator token #{token.name} (#{token.id}).")
          IO.puts("Store it now; it is not shown again:\n")
          IO.puts(plaintext)
          0

        {:error, changeset} ->
          error(changeset_errors(changeset))
      end
    end
  end

  def run(["operator-tokens", "list"]) do
    now = Renga.Time.utc_now_ms()

    for token <- Operators.list_tokens() do
      IO.puts(
        Enum.join(
          [
            token.id,
            token.name,
            token_status(token, now),
            Enum.join(token.scopes, ","),
            sources(token.allowed_sources),
            if(token.expires_at,
              do: "expires " <> DateTime.to_iso8601(token.expires_at),
              else: ""
            )
          ],
          "\t"
        )
      )
    end

    0
  end

  def run(["operator-tokens", "revoke" | args]) do
    with {:ok, context, _opts, rest, invalid} <- parse_change(args, []),
         {:ok, id_or_name} <- audited(context, "operator_token.revoke", one_arg(rest, invalid)) do
      case Operators.get_token(id_or_name) do
        nil ->
          {:error, :not_found} =
            DeploymentAudit.reject(context, "operator_token.revoke", :not_found)

          error("no operator token named or with ID #{id_or_name}")

        token ->
          {:ok, token} = Operators.revoke_token(token, context)
          IO.puts("Revoked operator token #{token.name} (#{token.id}).")
          0
      end
    end
  end

  def run(["limits", "show" | args]) do
    with {:ok, organization} <- organization_option(args, []) do
      Enum.each(Limits.list(organization), &print_limit/1)
      0
    end
  end

  # RFD 21: `renga-admin limits set --organization acme --job-creation-rate 600
  # --actor NAME`. Every setting applies, or none does.
  def run(["limits", "set" | args]) do
    switches = [organization: :string] ++ Enum.map(Limits.names(), &{&1, :integer})

    with {:ok, context, opts, rest, invalid} <- parse_change(args, switches),
         :ok <- audited(context, "limits.set", no_extra_args(rest, invalid)),
         {:ok, organization} <- audited_organization(context, "limits.set", opts),
         {:ok, settings} <- audited(context, "limits.set", limit_settings(opts)) do
      set_limits(organization, settings, context)
    end
  end

  def run(["limits", "clear" | args]) do
    switches = [organization: :string, limit: :string]

    with {:ok, context, opts, rest, invalid} <- parse_change(args, switches),
         :ok <- audited(context, "limits.clear", no_extra_args(rest, invalid)),
         {:ok, organization} <- audited_organization(context, "limits.clear", opts),
         {:ok, name} <- audited(context, "limits.clear", parse_limit(opts[:limit])) do
      :ok = Limits.clear(organization, name, context)
      IO.puts("Cleared #{limit_option(name)} for #{organization.slug}; the default applies.")
      0
    end
  end

  def run(_argv), do: error(@usage)

  defp set_limits(organization, settings, context) do
    case Limits.set(organization, settings, context) do
      :ok ->
        for {name, value} <- settings,
            do: IO.puts("Set #{limit_option(name)} to #{value} for #{organization.slug}.")

        0

      {:error, :invalid} ->
        error("limits must be from 0 to #{Limits.max_value()}")
    end
  end

  defp organization_option(args, switches) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [organization: :string] ++ switches)

    with :ok <- no_extra_args(rest, invalid), do: organization(opts)
  end

  defp organization(opts) do
    case opts[:organization] && Accounts.get_organization_by_slug(opts[:organization]) do
      nil -> error("--organization must name an existing organization by its slug")
      organization -> {:ok, organization}
    end
  end

  # An organization that does not exist is recorded as not found, without
  # the slug typed.
  defp audited_organization(context, operation, opts) do
    with status when is_integer(status) <- organization(opts) do
      {:error, :not_found} = DeploymentAudit.reject(context, operation, :not_found)
      status
    end
  end

  defp print_limit(limit) do
    source = if limit.overridden?, do: "override", else: "default"
    IO.puts(Enum.join([limit_option(limit.name), limit.value, limit.unit, source], "\t"))
  end

  defp limit_settings(opts) do
    settings = Keyword.take(opts, Limits.names())

    cond do
      settings == [] ->
        error("name at least one limit to set\n\n" <> @usage)

      not Enum.all?(settings, fn {_name, value} -> Limits.valid_value?(value) end) ->
        error("limits must be from 0 to #{Limits.max_value()}")

      true ->
        {:ok, settings}
    end
  end

  defp parse_limit(nil), do: error("--limit is required")

  defp parse_limit(value) do
    case Limits.parse_name(String.replace(value, "-", "_")) do
      {:ok, name} -> {:ok, name}
      :error -> error("unknown limit #{value}")
    end
  end

  defp limit_option(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  @doc """
  Entry point for `bin/renga-admin`: starts only the database, runs the
  command, and halts with its status.
  """
  def main(argv) do
    Renga.Release.with_repos(fn -> run(argv) end) |> System.halt()
  end

  # Like bin/providers, a change names who made it. Once it does, every
  # refusal of the command is recorded too, though never the arguments typed.
  defp parse_change(args, switches) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [actor: :string] ++ switches)

    with {:ok, context} <- context(opts), do: {:ok, context, opts, rest, invalid}
  end

  defp context(opts) do
    case opts[:actor] && String.trim(opts[:actor]) do
      actor when actor in [nil, ""] ->
        error("--actor NAME is required, so the change records who made it")

      actor ->
        if String.match?(actor, ~r/[[:cntrl:]]/u),
          do: error("--actor must not contain control characters"),
          else: {:ok, DeploymentAudit.operator(actor)}
    end
  end

  # Passes a step's result through, recording a refusal (an exit status) as
  # an `invalid` attempt at `operation`.
  defp audited(context, operation, status) when is_integer(status) do
    {:error, :invalid} = DeploymentAudit.reject(context, operation, :invalid)
    status
  end

  defp audited(_context, _operation, result), do: result

  defp one_arg([arg], []), do: {:ok, arg}
  defp one_arg(_rest, _invalid), do: error(@usage)

  defp token_attrs(opts) do
    scopes =
      Keyword.get_values(opts, :scope) ++
        Enum.flat_map(Keyword.get_values(opts, :scopes), &String.split(&1, ","))

    with {:ok, expires_at} <- parse_expiry(opts[:expires_at]),
         :ok <- no_empty_scopes(scopes) do
      {:ok,
       %{
         name: opts[:name],
         scopes: scopes,
         allowed_sources: Keyword.get_values(opts, :source),
         expires_at: expires_at
       }}
    end
  end

  defp no_empty_scopes(scopes) do
    if "" in scopes, do: error("--scopes must not have empty entries"), else: :ok
  end

  defp no_extra_args([], []), do: :ok
  defp no_extra_args(_rest, _invalid), do: error(@usage)

  defp parse_expiry(nil), do: {:ok, nil}

  defp parse_expiry(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, Renga.Time.floor_to_millisecond(datetime)}

      {:error, _reason} ->
        error("--expires-at must be an ISO 8601 time, such as 2027-01-01T00:00:00Z")
    end
  end

  defp token_status(token, now) do
    cond do
      token.revoked_at -> "revoked"
      token.expires_at && not DateTime.after?(token.expires_at, now) -> "expired"
      true -> "active"
    end
  end

  defp sources([]), do: "any source"
  defp sources(cidrs), do: Enum.map_join(cidrs, ",", &format_cidr/1)

  defp format_cidr(%Postgrex.INET{address: address, netmask: netmask}),
    do: "#{:inet.ntoa(address)}/#{netmask}"

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("\n", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error(message) do
    IO.puts(:stderr, message)
    1
  end
end
