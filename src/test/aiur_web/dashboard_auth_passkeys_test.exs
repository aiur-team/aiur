defmodule AiurWeb.DashboardAuthPasskeysTest do
  use ExUnit.Case, async: true

  alias AiurWeb.DashboardAuth.{ChallengeStore, Passkeys}

  test "Google authentication accepts only verified allowlisted emails" do
    assert AiurWeb.DashboardAuthController.allowed_google_user?(%{"email" => "Operator@gmail.com", "email_verified" => true}, ["operator@gmail.com"])
    refute AiurWeb.DashboardAuthController.allowed_google_user?(%{"email" => "operator@gmail.com", "email_verified" => false}, ["operator@gmail.com"])
    refute AiurWeb.DashboardAuthController.allowed_google_user?(%{"email" => "other@gmail.com", "email_verified" => true}, ["operator@gmail.com"])
  end

  test "a passkey challenge is single-use across requests" do
    name = Module.concat(__MODULE__, ChallengeStore)
    store = start_supervised!({ChallengeStore, name: name})
    challenge = Wax.new_registration_challenge(origin: "https://aiur.example.test", rp_id: "aiur.example.test", user_verification: "required")

    assert {:ok, challenge_id} = ChallengeStore.put(challenge, store)
    assert {:ok, ^challenge} = ChallengeStore.take(challenge_id, store)
    assert {:error, :challenge_missing_or_replayed} = ChallengeStore.take(challenge_id, store)
  end

  test "passkey challenge storage is bounded and releases expired slots" do
    name = Module.concat(__MODULE__, BoundedChallengeStore)
    clock = start_supervised!({Agent, fn -> 0 end})
    now_fun = fn -> Agent.get(clock, & &1) end
    store = start_supervised!({ChallengeStore, name: name, max_entries: 1, ttl_ms: 250, now_fun: now_fun})
    challenge = Wax.new_registration_challenge(origin: "https://aiur.example.test", rp_id: "aiur.example.test", user_verification: "required")

    assert {:ok, _challenge_id} = ChallengeStore.put(challenge, store)
    assert {:error, :capacity_exceeded} = ChallengeStore.put(challenge, store)

    Agent.update(clock, &(&1 + 250))

    assert {:ok, _replacement_id} = ChallengeStore.put(challenge, store)
  end

  test "one remote owner cannot consume every pending challenge slot" do
    name = Module.concat(__MODULE__, PerOwnerChallengeStore)
    store = start_supervised!({ChallengeStore, name: name, max_entries: 3, max_entries_per_owner: 1})
    challenge = Wax.new_authentication_challenge(origin: "https://aiur.example.test", rp_id: "aiur.example.test")

    assert {:ok, first_id} = ChallengeStore.put(challenge, store, {10, 0, 0, 1})
    assert {:error, :capacity_exceeded} = ChallengeStore.put(challenge, store, {10, 0, 0, 1})
    assert {:ok, _second_id} = ChallengeStore.put(challenge, store, {10, 0, 0, 2})
    assert {:ok, ^challenge} = ChallengeStore.take(first_id, store)
    assert {:ok, _replacement_id} = ChallengeStore.put(challenge, store, {10, 0, 0, 1})
  end

  test "authenticator counters allow unsupported 0-to-0 and reject a decrease" do
    assert Passkeys.sign_count_valid?(0, 0)
    assert Passkeys.sign_count_valid?(8, 9)
    refute Passkeys.sign_count_valid?(8, 8)
    refute Passkeys.sign_count_valid?(9, 8)
  end

  test "malformed assertions return an error instead of raising" do
    challenge = Wax.new_authentication_challenge(origin: "https://aiur.example.test", rp_id: "aiur.example.test")

    assert {:error, :invalid_assertion} = Passkeys.authenticate(challenge, "not a map")
    assert {:error, :invalid_assertion} = Passkeys.authenticate(challenge, %{"rawId" => "!"})
  end
end
