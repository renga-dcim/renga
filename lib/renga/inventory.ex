defmodule Renga.Inventory do
  @moduledoc """
  Inventory source and resource management.
  """

  import Ecto.Query, warn: false

  alias Renga.Accounts.Scope
  alias Renga.Inventory.Source
  alias Renga.Repo

  @source_token_prefix "renga_src_"
  @source_token_bytes 32

  def list_sources(%Scope{organization_id: organization_id}) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> order_by([source], asc: source.name)
    |> Repo.all()
  end

  def get_source!(%Scope{organization_id: organization_id}, id) do
    Source
    |> where([source], source.organization_id == ^organization_id)
    |> Repo.get!(id)
  end

  def create_source(%Scope{organization_id: organization_id}, attrs) do
    %Source{organization_id: organization_id}
    |> Source.changeset(attrs)
    |> Repo.insert()
  end

  def create_source_with_token(%Scope{organization_id: organization_id}, attrs) do
    token = generate_source_token()

    result =
      %Source{organization_id: organization_id}
      |> Source.changeset(attrs)
      |> Ecto.Changeset.put_change(:token_hash, hash_source_token(token))
      |> Repo.insert()

    case result do
      {:ok, source} -> {:ok, {source, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def update_source(%Source{} = source, attrs) do
    source
    |> Source.changeset(attrs)
    |> Repo.update()
  end

  def change_source(%Source{} = source, attrs \\ %{}) do
    Source.changeset(source, attrs)
  end

  def rotate_source_token(%Scope{} = scope, source_id) do
    source = get_source!(scope, source_id)
    token = generate_source_token()

    result =
      source
      |> Source.token_changeset(hash_source_token(token))
      |> Repo.update()

    case result do
      {:ok, source} -> {:ok, {source, token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def revoke_source_token(%Scope{} = scope, source_id) do
    scope
    |> get_source!(source_id)
    |> Source.revoke_changeset()
    |> Repo.update()
  end

  def authenticate_source_token(@source_token_prefix <> _rest = token) do
    token_hash = hash_source_token(token)

    Source
    |> where([source], source.token_hash == ^token_hash)
    |> where([source], source.status == "active")
    |> Repo.one()
    |> case do
      %Source{} = source -> {:ok, source}
      nil -> :error
    end
  end

  def authenticate_source_token(_token), do: :error

  defp generate_source_token do
    @source_token_prefix <>
      Base.url_encode64(:crypto.strong_rand_bytes(@source_token_bytes), padding: false)
  end

  defp hash_source_token(token), do: :crypto.hash(:sha256, token)
end
