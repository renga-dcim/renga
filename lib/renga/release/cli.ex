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
  alias Renga.Transfers
  alias Renga.Transfers.Export
  alias Renga.Transfers.Import

  @usage """
  Usage:
    renga-admin operator-tokens create --actor NAME --name NAME --scopes SCOPE[,SCOPE...]
                                       [--expires-at ISO8601] [--source CIDR...]
    renga-admin operator-tokens list
    renga-admin operator-tokens revoke ID_OR_NAME --actor NAME
    renga-admin limits show --organization SLUG
    renga-admin limits set --organization SLUG --actor NAME --LIMIT VALUE [--LIMIT VALUE...]
    renga-admin limits clear --organization SLUG --actor NAME --limit LIMIT
    renga-admin export --organization SLUG --output FILE --actor NAME
                       [--history] [--raw-observations]
    renga-admin import --organization SLUG --input FILE --owner EMAIL --actor NAME

  Changes, exports, and imports need --actor, the person running them, which the
  deployment audit log records with an invocation ID. --scope SCOPE may also
  be repeated.

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

  # RFD 20: writes the same archive an owner's export does. The file holds
  # the whole organization, so it is created readable only by its owner and
  # never replaces an existing file.
  def run(["export" | args]) do
    switches = [
      organization: :string,
      output: :string,
      history: :boolean,
      raw_observations: :boolean
    ]

    with {:ok, context, opts, rest, invalid} <- parse_change(args, switches),
         :ok <- audited(context, "organization.export", no_extra_args(rest, invalid)),
         {:ok, organization} <- audited_organization(context, "organization.export", opts),
         {:ok, output} <- audited(context, "organization.export", output_file(opts[:output])) do
      parts =
        for {option, part} <- [history: "history", raw_observations: "raw_observations"],
            opts[option],
            do: part

      export(organization, output, parts, context)
    end
  end

  # RFD 20: the organization's owner, its only member, is the person
  # importing; they invite everyone else back afterwards.
  def run(["import" | args]) do
    with {:ok, context, opts, rest, invalid} <-
           parse_change(args, organization: :string, input: :string, owner: :string),
         :ok <- audited(context, "organization.import", no_extra_args(rest, invalid)),
         {:ok, organization} <- audited_organization(context, "organization.import", opts),
         {:ok, input} <- audited(context, "organization.import", input_file(opts[:input])),
         {:ok, owner} <-
           audited(context, "organization.import", import_owner(organization, opts[:owner])) do
      import_archive(organization, input, owner, context)
    end
  end

  def run(_argv), do: error(@usage)

  defp import_owner(_organization, nil),
    do: error("--owner EMAIL is required: the organization's owner, who invites everyone back")

  defp import_owner(organization, email) do
    with %Accounts.User{} = user <- Accounts.get_user_by_email(email),
         %{role: "owner", status: "active"} <-
           Accounts.get_membership_for_user(organization, user.id) do
      {:ok, user}
    else
      _not_an_owner -> error("#{email} is not an active owner of #{organization.slug}")
    end
  end

  defp import_archive(organization, input, owner, context) do
    details = %{organization: organization, target_id: organization.id}

    case Import.run(organization, input,
           operator: DeploymentAudit.actor_label(context),
           imported_by_user_id: owner.id
         ) do
      {:ok, imported} ->
        :ok = DeploymentAudit.succeeded(context, "organization.import", details)

        IO.puts(
          "Imported #{imported.records} records from an export of #{imported.source_slug} " <>
            "into #{organization.slug}."
        )

        if imported.held_settings != %{},
          do:
            IO.puts(
              "Settings held for an owner to confirm: #{Renga.JSON.encode!(imported.held_settings)}"
            )

        IO.puts("#{owner.email} can invite people back from Settings → Members.")

        0

      {:error, reason} ->
        :ok = DeploymentAudit.failed(context, "organization.import", details)
        error(import_error(reason, organization))
    end
  end

  defp import_error({:invalid, problems}, _organization) do
    lines =
      Enum.map(problems, fn problem ->
        where = [problem.file, problem.line] |> Enum.reject(&is_nil/1) |> Enum.join(":")
        if where == "", do: "  #{problem.message}", else: "  #{where}: #{problem.message}"
      end)

    Enum.join(["The archive is not valid:" | lines], "\n")
  end

  defp import_error(:not_empty, organization),
    do: "#{organization.slug} is not empty; import into a new organization"

  defp import_error({:id_collisions, counts}, _organization) do
    counts = Enum.map_join(counts, ", ", fn {type, count} -> "#{count} #{type}" end)

    "records in the archive already exist in this deployment (#{counts}); " <>
      "remove the original organization first"
  end

  defp input_file(nil), do: error("--input FILE is required")

  defp input_file(path) do
    if File.regular?(path), do: {:ok, path}, else: error("#{path} is not a file")
  end

  # The archive is written in a new 0700 directory beside the output, so no
  # one else can open it while it is written, and then hard-linked into
  # place, which fails rather than replace a file that appeared meanwhile.
  defp export(organization, output, parts, context) do
    staging =
      Path.join(
        Path.dirname(output),
        ".renga-export-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      )

    partial = Path.join(staging, "archive.tar.zst")
    details = %{organization: organization, target_id: organization.id}

    try do
      File.mkdir!(staging)
      File.chmod!(staging, 0o700)
      File.touch!(partial)
      File.chmod!(partial, 0o600)
      {:ok, summary} = Export.write(organization, partial, parts: parts)

      case File.ln(partial, output) do
        :ok ->
          :ok = DeploymentAudit.succeeded(context, "organization.export", details)
          :ok = Transfers.record_operator_export(organization, context)

          IO.puts(
            "Exported #{organization.slug} (#{summary.records} records, snapshot at " <>
              "#{DateTime.to_iso8601(summary.snapshot_at)}) to #{output}."
          )

          0

        {:error, :eexist} ->
          DeploymentAudit.reject(context, "organization.export", :output_exists, details)
          error("#{output} was created during the export and was left as it is")

        {:error, reason} ->
          raise File.LinkError, reason: reason, action: "link", existing: partial, new: output
      end
    rescue
      exception ->
        :ok = DeploymentAudit.failed(context, "organization.export", details)
        reraise exception, __STACKTRACE__
    after
      File.rm_rf(staging)
    end
  end

  defp output_file(nil), do: error("--output FILE is required")

  defp output_file(path) do
    cond do
      File.exists?(path) -> error("#{path} already exists; choose a new file")
      not File.dir?(Path.dirname(path)) -> error("#{Path.dirname(path)} is not a directory")
      true -> {:ok, path}
    end
  end

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
