defmodule Renga.Accounts.TOTPFixtureTest do
  @moduledoc """
  `totp_fixture/2` must enable an authenticator app when Renga checks its
  code a step or two after the fixture read the time, and leave the current
  step for the test. Renga reads the real clock, so each test moves the
  fixture's clock instead: a fixture clock behind the real one is a stall
  between the fixture reading the time and Renga checking the code.
  """
  # Swaps the Vault keys in the application environment, so not async.
  use Renga.DataCase, async: false

  import Renga.AccountsFixtures

  alias Renga.Accounts.MFA
  alias Renga.Accounts.SecurityEvent
  alias Renga.Accounts.UserTOTP

  # A clock reading `base` plus each offset in turn, repeating the list,
  # that counts its reads and refuses to be read more than 20 times.
  defp clock(offsets, base \\ fn -> System.os_time(:second) end) do
    reads = :counters.new(1, [])

    now = fn ->
      :counters.add(reads, 1, 1)
      n = :counters.get(reads, 1)
      if n > 20, do: raise("the fixture read its clock #{n} times")
      base.() + Enum.at(offsets, rem(n - 1, length(offsets)))
    end

    {now, fn -> :counters.get(reads, 1) end}
  end

  defp step, do: div(System.os_time(:second), 30)

  # A secret whose codes differ at every step from three before now to
  # three after, and at `extra`, so a code the test means to be refused
  # cannot share digits with one Renga accepts, even across a boundary.
  defp distinct_secret(extra \\ []) do
    steps = Enum.to_list((step() - 3)..(step() + 3)) ++ extra
    secret = MFA.new_totp_secret()
    codes = for s <- steps, do: NimbleTOTP.verification_code(secret, time: s * 30)

    if length(Enum.uniq(codes)) == length(codes), do: secret, else: distinct_secret(extra)
  end

  defp events(user, kind),
    do: Repo.aggregate(where(SecurityEvent, user_id: ^user.id, kind: ^kind), :count)

  defp last_used_step(user), do: Repo.one!(where(UserTOTP, user_id: ^user.id)).last_used_step

  # The fixture's promise: an app with a fresh set of recovery codes, and
  # the code the app shows now still unused.
  defp assert_enabled_with_current_step_unused(user, {secret, codes}) do
    assert length(Enum.uniq(codes)) == 10
    assert MFA.recovery_codes_left(user) == 10
    assert events(user, "recovery_codes_generated") == 1
    assert last_used_step(user) < step()
    assert :ok = MFA.verify_totp(user, NimbleTOTP.verification_code(secret))
    assert :ok = MFA.spend_recovery_code(user, hd(codes))
    assert MFA.recovery_codes_left(user) == 9
  end

  test "spends only the step before the current one" do
    user = user_fixture()
    before = step()
    enabled = totp_fixture(user)

    assert last_used_step(user) in (before - 1)..(step() - 1)
    assert events(user, "totp_enable_failed") == 0
    assert_enabled_with_current_step_unused(user, enabled)
  end

  test "a stall of a whole step needs no retry" do
    user = user_fixture()
    {now, reads} = clock([-30, 0])
    before = step()
    enabled = totp_fixture(user, now: now)

    # Only another, real boundary during the call can cost an attempt.
    if step() == before, do: assert(reads.() == 2)
    assert_enabled_with_current_step_unused(user, enabled)
  end

  test "a clock that went back a step leaves the step it went back to unused" do
    user = user_fixture()
    # A step ahead when the fixture makes its code, back on the real step
    # once Renga accepted it as the next one.
    real = step() * 30
    {now, reads} = clock([30, 0], fn -> real end)
    enabled = totp_fixture(user, now: now)

    assert reads.() == 2
    assert last_used_step(user) == div(real, 30) - 1
    assert_enabled_with_current_step_unused(user, enabled)
  end

  test "a stall of two steps is retried with a code for the new step" do
    user = user_fixture()
    {now, reads} = clock([-60, 0, 0, 0])
    enabled = totp_fixture(user, now: now, secret: distinct_secret())

    assert reads.() == 4
    assert events(user, "totp_enable_failed") == 1
    assert_enabled_with_current_step_unused(user, enabled)
  end

  test "a clock that keeps jumping gives up after three attempts" do
    user = user_fixture()
    {now, reads} = clock([-60, 0])

    assert_raise RuntimeError, ~r/:invalid_code/, fn ->
      totp_fixture(user, now: now, secret: distinct_secret())
    end

    assert reads.() == 5
    assert events(user, "totp_enable_failed") == 3
    refute MFA.totp_enabled?(user)
    assert MFA.recovery_codes_left(user) == 0
  end

  test "a refused code is not retried when the clock moved at most a step" do
    user = user_fixture()
    # An hour ahead of Renga, so the code is refused, with exactly one
    # boundary during the call whatever the real clock does.
    hour_ahead = div(System.os_time(:second) + 3600, 30) * 30
    {now, reads} = clock([0, 30], fn -> hour_ahead end)
    secret = distinct_secret([div(hour_ahead, 30)])

    assert_raise RuntimeError, ~r/refused a code for the current step/, fn ->
      totp_fixture(user, now: now, secret: secret)
    end

    assert reads.() == 2
    assert events(user, "totp_enable_failed") == 1
    refute MFA.totp_enabled?(user)
  end

  test "other failures are raised without a retry" do
    user = user_fixture()
    totp_fixture(user)
    {now, reads} = clock([0])

    assert_raise RuntimeError, ~r/:already_enabled/, fn -> totp_fixture(user, now: now) end
    assert reads.() == 1

    vault = Application.get_env(:renga, Renga.Vault)
    on_exit(fn -> Application.put_env(:renga, Renga.Vault, vault) end)
    Application.put_env(:renga, Renga.Vault, keys: [])
    other = user_fixture()
    {now, reads} = clock([0])

    assert_raise RuntimeError, ~r/:no_encryption_key/, fn -> totp_fixture(other, now: now) end
    assert reads.() == 1
    refute MFA.totp_enabled?(other)
  end
end
