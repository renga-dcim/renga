defmodule Renga.Accounts.EmailInitializationTest do
  use Renga.DataCase, async: true

  import Renga.AccountsFixtures
  import Renga.InventoryFixtures

  alias Renga.Accounts
  alias Renga.Accounts.AccountChallenge
  alias Renga.Accounts.Recheck
  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.User

  # The account an organization provider's sign-up creates (RFD 15): no
  # email, no credential, and a session scoped to the organization.
  setup do
    organization = organization_fixture()
    user = Repo.insert!(%User{})
    organization_membership_fixture(user, organization)
    {token, session_user} = scoped_session(user, organization)

    %{organization: organization, user: session_user, token: token}
  end

  defp scoped_session(user, organization) do
    token =
      Accounts.generate_user_session_token(%{user | session_organization_id: organization.id})

    {session_user, _inserted_at} = Accounts.get_user_by_session_token(token)
    {token, session_user}
  end

  # Without ending the account's sessions, as `set_password/1` would.
  defp add_password(user) do
    user
    |> User.password_changeset(%{password: valid_user_password()})
    |> Repo.update!()
  end

  defp code(user, token, email) do
    {:ok, sent} = Recheck.deliver_email_initialization_code(user, token, email)
    assert sent.to == [{"", email}]
    [code] = Regex.run(~r/[A-Z0-9]{5}-[A-Z0-9]{5}/, sent.text_body)
    code
  end

  test "a code sent to the chosen address makes it the confirmed login email", %{
    user: user,
    token: token
  } do
    code = code(user, token, "sam@personal.example")

    assert {:ok, updated} = Recheck.verify_email_initialization_code(user, token, code)
    assert updated.email == "sam@personal.example"
    assert updated.session_organization_id == user.session_organization_id

    stored = Repo.get!(User, user.id)
    assert stored.email == "sam@personal.example"
    assert stored.confirmed_at

    assert [%SecurityEvent{kind: "email_initialized"}] =
             Repo.all(from e in SecurityEvent, where: e.user_id == ^user.id)
  end

  test "grants only the first password or factor, even to the scoped session", %{
    user: user,
    token: token
  } do
    refute Recheck.authorized?(user, token, :set_password)

    code = code(user, token, "sam@personal.example")
    {:ok, user} = Recheck.verify_email_initialization_code(user, token, code)

    assert Recheck.authorized?(user, token, :set_password)
    assert Recheck.authorized?(user, token, :add_factor)

    for change <- [
          :change_email,
          :remove_factor,
          :recovery_codes,
          :link_identity,
          :unlink_identity
        ] do
      refute Recheck.authorized?(user, token, change)
    end

    # Nor is it a re-check the email bootstrap or a password could give.
    assert {:error, :no_session} = Recheck.deliver_bootstrap_code(user, token)

    # Once the first credential exists the bootstrap is over.
    user = add_password(user)
    refute Recheck.authorized?(user, token, :set_password)
    refute Recheck.authorized?(user, token, :add_factor)
  end

  test "is bound to the session that asked for it", %{
    organization: organization,
    user: user,
    token: token
  } do
    code = code(user, token, "sam@personal.example")
    {other_token, _user} = scoped_session(user, organization)

    assert {:error, :expired} = Recheck.verify_email_initialization_code(user, other_token, code)
    refute Recheck.authorized?(user, other_token, :set_password)
    assert Repo.get!(User, user.id).email == nil
  end

  test "stops accepting codes after five wrong attempts", %{user: user, token: token} do
    code = code(user, token, "sam@personal.example")

    for _ <- 1..5 do
      assert {:error, :invalid_code} =
               Recheck.verify_email_initialization_code(user, token, "WRONG-CODE0")
    end

    assert {:error, :too_many_attempts} =
             Recheck.verify_email_initialization_code(user, token, code)
  end

  test "expires after five minutes", %{user: user, token: token} do
    code = code(user, token, "sam@personal.example")

    Repo.update_all(AccountChallenge,
      set: [expires_at: DateTime.add(Renga.Time.utc_now_ms(), -1, :second)]
    )

    assert {:error, :expired} = Recheck.verify_email_initialization_code(user, token, code)
  end

  test "a new code replaces the earlier one and its address", %{user: user, token: token} do
    first = code(user, token, "sam@old.example")
    second = code(user, token, "sam@new.example")

    assert {:error, :invalid_code} = Recheck.verify_email_initialization_code(user, token, first)

    assert {:ok, %User{email: "sam@new.example"}} =
             Recheck.verify_email_initialization_code(user, token, second)
  end

  test "refuses an address that belongs to another account", %{user: user, token: token} do
    other = user_fixture()

    assert {:error, %Ecto.Changeset{} = changeset} =
             Recheck.deliver_email_initialization_code(user, token, other.email)

    assert %{email: ["has already been taken"]} = errors_on(changeset)

    assert {:error, %Ecto.Changeset{}} =
             Recheck.deliver_email_initialization_code(user, token, "not an address")

    refute_received {:email, %{subject: "Your Renga confirmation code"}}
  end

  test "refuses an address someone registered after the code went out", %{
    user: user,
    token: token
  } do
    code = code(user, token, "sam@personal.example")
    other = user_fixture(%{email: "sam@personal.example"})

    assert {:error, :email_in_use} = Recheck.verify_email_initialization_code(user, token, code)
    assert Repo.get!(User, user.id).email == nil
    assert Repo.get!(User, other.id).email == "sam@personal.example"
    refute Recheck.authorized?(user, token, :set_password)
  end

  test "never replaces an email or reaches an account with a credential", %{
    organization: organization
  } do
    with_email = user_fixture()
    {token, session_user} = scoped_session(with_email, organization)

    assert {:error, :not_available} =
             Recheck.deliver_email_initialization_code(session_user, token, "x@personal.example")

    unscoped = Accounts.generate_user_session_token(with_email)

    assert {:error, :not_available} =
             Recheck.deliver_email_initialization_code(with_email, unscoped, "x@personal.example")

    with_password =
      %User{}
      |> User.password_changeset(%{password: valid_user_password()})
      |> Repo.insert!()

    {token, session_user} = scoped_session(with_password, organization)

    assert {:error, :not_available} =
             Recheck.deliver_email_initialization_code(session_user, token, "y@personal.example")
  end

  test "a code sent before the account got a credential no longer works", %{
    user: user,
    token: token
  } do
    code = code(user, token, "sam@personal.example")
    add_password(user)

    assert {:error, :not_available} = Recheck.verify_email_initialization_code(user, token, code)
    assert Repo.get!(User, user.id).email == nil
  end

  test "needs a session of this account", %{organization: organization, user: user} do
    {other_token, _other} = scoped_session(user_fixture(), organization)

    assert {:error, :no_session} =
             Recheck.deliver_email_initialization_code(user, other_token, "sam@personal.example")

    assert {:error, :no_session} =
             Recheck.deliver_email_initialization_code(user, "bogus", "sam@personal.example")
  end
end
