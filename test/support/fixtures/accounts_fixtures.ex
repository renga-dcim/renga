defmodule Renga.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Renga.Accounts` context.
  """

  import Ecto.Query

  alias Renga.Accounts
  alias Renga.Accounts.Scope

  @doc "A six-digit code that matches no step of `secret` near now."
  def wrong_totp_code(secret) do
    now = System.os_time(:second)
    valid = for offset <- -2..2, do: NimbleTOTP.verification_code(secret, time: now + offset * 30)

    Stream.repeatedly(fn -> :rand.uniform(1_000_000) - 1 end)
    |> Stream.map(&String.pad_leading(Integer.to_string(&1), 6, "0"))
    |> Enum.find(&(&1 not in valid))
  end

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  @doc """
  Turns on an authenticator app for `user` and leaves the current step
  unused, so a test can still sign in with the code its app shows now.
  Returns `{secret, recovery_codes}`.

  `:now` replaces the fixture's clock, in Unix seconds, so a test can put
  a stall between the fixture reading the time and Renga checking the code.
  `:secret` replaces the random secret.
  """
  def totp_fixture(user, opts \\ []) do
    now = Keyword.get(opts, :now, fn -> System.os_time(:second) end)
    secret = Keyword.get_lazy(opts, :secret, &Accounts.MFA.new_totp_secret/0)
    {secret, enable_totp_unused(user, secret, now, 3)}
  end

  # Renga accepts a code for the step it reads and the steps either side.
  # A code for the previous step falls out of that window at the next
  # boundary, so the fixture proves the current step's code, which lasts
  # until a second boundary, and then marks as used the step before the
  # earliest it read, in case the clock went back. That also keeps the
  # current step unused if its code happened to match a later one.
  #
  # Only a failure the clock explains is retried: it moved more than a step
  # during the attempt, so the code may have expired. Each retry leaves a
  # `totp_enable_failed` event, and any other failure is raised.
  defp enable_totp_unused(user, secret, now, attempts) do
    step = div(now.(), 30)
    code = NimbleTOTP.verification_code(secret, time: step * 30)

    case Accounts.MFA.enable_totp(user, secret, code) do
      {:ok, codes} ->
        {1, _} =
          Renga.Repo.update_all(where(Accounts.UserTOTP, user_id: ^user.id),
            set: [last_used_step: min(step, div(now.(), 30)) - 1]
          )

        codes

      {:error, :invalid_code} when attempts > 1 ->
        if abs(div(now.(), 30) - step) > 1,
          do: enable_totp_unused(user, secret, now, attempts - 1),
          else: raise("totp_fixture: Renga refused a code for the current step")

      error ->
        raise "totp_fixture: enable_totp/3 returned #{inspect(error)}"
    end
  end

  @doc """
  An active deployment OpenID Connect provider for `fake`, a
  `Renga.FakeOIDCProvider`. Activation is set directly here; the real path is
  a test sign-in.
  """
  def identity_provider_fixture(fake, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "id" => "idp-#{System.unique_integer([:positive])}",
          "kind" => "oidc",
          "issuer" => fake.issuer,
          "display_name" => "Company SSO",
          "client_id" => fake.client_id,
          "client_secret" => "client-secret",
          "allow_sign_up" => true
        },
        attrs
      )

    {:ok, {provider, _revision}} =
      Accounts.IdentityProviders.create(attrs, {:operator, "fixture"})

    provider
    |> Ecto.Changeset.change(active_revision: 1, pending_revision: nil)
    |> Renga.Repo.update!()
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Renga.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Renga.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(Renga.Time.utc_now_ms(), amount_to_add, unit)

    Renga.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
