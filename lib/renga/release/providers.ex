defmodule Renga.Release.Providers do
  @moduledoc """
  `bin/providers`, the operator's commands for deployment identity providers
  (RFD 15, "Operators"). They work when nobody can sign in, because they run
  on the server rather than through the web interface.

      bin/providers list
      bin/providers add --actor NAME --id ID --issuer URL --name NAME --client-id ID
                        [--scopes a,b] [--email-domains a.com,b.com] [--allow-sign-up] [--hidden]
      bin/providers add --actor NAME --id ID --kind github --name NAME --client-id ID
                        [--email-domains a.com,b.com] [--hidden]
      bin/providers update ID --actor NAME [--client-id ID] [--scopes ...] [--email-domains ...]
                        [--allow-sign-up | --no-allow-sign-up] [--name NAME] [--hidden | --no-hidden]
      bin/providers test ID --actor NAME
      bin/providers enable ID --actor NAME
      bin/providers disable ID --actor NAME
      bin/providers recover-local --actor NAME --minutes N [--disable ID]
      bin/providers recover-local --actor NAME --revoke

  A client secret is never an argument, where it would show in the process
  list and shell history: `add` and `update` read it from the
  `RENGA_CLIENT_SECRET` environment variable when it is set. `add` and
  `update` leave the new settings pending; `test` prints a single-use link
  that tests them in a browser and activates them.

  A `github` provider has no issuer and never creates accounts: people
  link it to an account they already have, then sign in with it.
  """

  alias Renga.Accounts.IdentityProviders
  alias Renga.Accounts.SignInPolicy

  @switches [
    actor: :string,
    id: :string,
    kind: :string,
    issuer: :string,
    name: :string,
    client_id: :string,
    scopes: :string,
    email_domains: :string,
    allow_sign_up: :boolean,
    hidden: :boolean,
    minutes: :integer,
    disable: :string,
    revoke: :boolean
  ]

  @doc "Runs a command. Returns `{:ok, output}` or `{:error, message}`."
  def run(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [command | args], []} ->
        command(command, args, opts)

      {_opts, [], []} ->
        {:error, usage()}

      {_opts, _args, invalid} ->
        {:error, "unknown or invalid options: #{inspect(invalid)}\n" <> usage()}
    end
  end

  defp command("list", [], _opts) do
    rows =
      for provider <- IdentityProviders.list() do
        [
          provider.id,
          provider.kind,
          provider.display_name,
          if(provider.enabled, do: "enabled", else: "disabled"),
          "active #{provider.active_revision || "-"}",
          "pending #{provider.pending_revision || "-"}",
          if(provider.hidden, do: "hidden", else: "")
        ]
        |> Enum.join("\t")
      end

    {:ok, Enum.join(["local sign-in: #{local_status()}" | rows], "\n")}
  end

  defp command("add", [], opts) do
    with {:ok, actor} <- actor(opts) do
      attrs =
        %{
          "id" => opts[:id],
          "kind" => opts[:kind] || "oidc",
          "issuer" => opts[:issuer],
          "display_name" => opts[:name],
          "hidden" => opts[:hidden] || false
        }
        |> Map.merge(revision_attrs(opts))

      case IdentityProviders.create(attrs, actor) do
        {:ok, {provider, _revision}} ->
          {:ok,
           "Added #{provider.id}, pending. Run `bin/providers test #{provider.id}` to activate it."}

        error ->
          failure(error)
      end
    end
  end

  defp command("update", [id], opts) do
    with {:ok, actor} <- actor(opts),
         {:ok, provider} <- fetch(id),
         {:ok, provider} <- update_display(provider, opts, actor),
         {:ok, message} <- update_revision(provider, opts, actor) do
      {:ok, message}
    else
      error -> failure(error)
    end
  end

  defp command("test", [id], opts) do
    with {:ok, actor} <- actor(opts),
         {:ok, provider} <- fetch(id),
         {:ok, {token, test}} <- IdentityProviders.create_test(provider, actor) do
      {:ok,
       "Open this link within 15 minutes to test revision #{test.revision} of #{id}. " <>
         "It works once, and a successful sign-in activates the revision:\n" <>
         base_url() <> "/users/providers/test/" <> token}
    else
      error -> failure(error)
    end
  end

  defp command(command, [id], opts) when command in ["enable", "disable"] do
    with {:ok, actor} <- actor(opts),
         {:ok, provider} <- fetch(id),
         {:ok, provider} <-
           apply(IdentityProviders, String.to_existing_atom(command), [provider, actor]) do
      {:ok, "#{provider.id} is #{if provider.enabled, do: "enabled", else: "disabled"}."}
    else
      error -> failure(error)
    end
  end

  defp command("recover-local", [], opts) do
    with {:ok, {:operator, actor}} <- actor(opts) do
      recover_local(opts, actor)
    end
  end

  defp command(_command, _args, _opts), do: {:error, usage()}

  defp recover_local(opts, actor) do
    cond do
      opts[:revoke] ->
        {:ok, count} = SignInPolicy.revoke_overrides(actor)
        {:ok, "Revoked #{count} local sign-in override(s). Local sign-in is #{local_status()}."}

      is_integer(opts[:minutes]) and opts[:minutes] in 1..(24 * 60) ->
        case SignInPolicy.recover_local(opts[:minutes], actor, disable: opts[:disable]) do
          {:ok, override} ->
            {:ok,
             "Local sign-in is on until #{DateTime.to_iso8601(override.expires_at)}." <>
               if(opts[:disable], do: " Disabled #{opts[:disable]}.", else: "") <>
               " Registration is unchanged."}

          error ->
            failure(error)
        end

      true ->
        {:error, "recover-local needs --minutes between 1 and 1440, or --revoke"}
    end
  end

  defp update_display(provider, opts, actor) do
    attrs =
      %{"display_name" => opts[:name], "hidden" => opts[:hidden]}
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    if attrs == %{},
      do: {:ok, provider},
      else: IdentityProviders.update_display(provider, attrs, actor)
  end

  defp update_revision(provider, opts, actor) do
    case revision_attrs(opts) do
      attrs when attrs == %{} ->
        {:ok, "Updated #{provider.id}."}

      attrs ->
        with {:ok, {provider, revision}} <-
               IdentityProviders.propose_revision(provider, attrs, actor) do
          {:ok,
           "Revision #{revision.number} of #{provider.id} is pending. " <>
             "Run `bin/providers test #{provider.id}` to activate it."}
        end
    end
  end

  defp revision_attrs(opts) do
    %{
      "client_id" => opts[:client_id],
      "client_secret" => System.get_env("RENGA_CLIENT_SECRET"),
      "scopes" => split(opts[:scopes]),
      "email_domains" => split(opts[:email_domains]),
      "allow_sign_up" => opts[:allow_sign_up]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp split(nil), do: nil
  defp split(list), do: String.split(list, ",", trim: true)

  defp actor(opts) do
    case opts[:actor] do
      actor when is_binary(actor) and actor != "" -> {:ok, {:operator, actor}}
      _missing -> {:error, "--actor NAME is required, so the change records who made it"}
    end
  end

  defp fetch(id) do
    case IdentityProviders.get(id) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  defp local_status do
    cond do
      SignInPolicy.configured_local_sign_in?() ->
        "enabled"

      override = SignInPolicy.active_override() ->
        "enabled by an override until #{override.expires_at}"

      true ->
        "disabled"
    end
  end

  defp failure({:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, keys} ->
        Enum.reduce(keys, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    {:error,
     Enum.map_join(errors, "\n", fn {field, messages} ->
       "#{field}: #{Enum.join(messages, ", ")}"
     end)}
  end

  defp failure({:error, :not_found}), do: {:error, "No provider has that ID."}
  defp failure({:error, :no_changes}), do: {:error, "Nothing to change."}

  defp failure({:error, :nothing_pending}),
    do: {:error, "Nothing is pending. Update the provider first."}

  defp failure({:error, :last_sign_in_method}),
    do:
      {:error,
       "Refused: nobody could sign in afterwards. Use recover-local --disable to do this."}

  defp failure({:error, :no_encryption_key}),
    do: {:error, "Set ENCRYPTION_KEYS before saving a client secret."}

  defp failure({:error, message}) when is_binary(message), do: {:error, message}
  defp failure({:error, reason}), do: {:error, "Failed: #{inspect(reason)}"}

  # The release does not start the endpoint, so its URL comes from config,
  # falling back to the listener the way Phoenix does when `url` leaves the
  # scheme or port out.
  defp base_url do
    config = Application.get_env(:renga, RengaWeb.Endpoint, [])
    url = config[:url] || []

    {scheme, listener} =
      if config[:https], do: {"https", config[:https]}, else: {"http", config[:http] || []}

    scheme = Keyword.get(url, :scheme, scheme)
    host = Keyword.get(url, :host, "localhost")
    port = Keyword.get(url, :port, listener[:port])

    default_port? = {scheme, port} in [{"https", 443}, {"http", 80}] or is_nil(port)
    "#{scheme}://#{host}#{if default_port?, do: "", else: ":#{port}"}"
  end

  defp usage, do: @moduledoc |> String.split("\n\n") |> Enum.at(1) |> String.trim()
end
