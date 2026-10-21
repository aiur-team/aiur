defmodule Aiur.GitHub.AuthPreflight.LocalHoldTest do
  import Aiur.GitHub.AuthPreflight.TestFixtures

  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.ReadCache

  @token_cache_key {Aiur.GitHub.Access.Token, :resolved_token}
  @source_cache_key {Aiur.GitHub.Access.Token, :resolved_token_source}

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(@token_cache_key, :unset)
    prev_source = :persistent_term.get(@source_cache_key, :unset)
    :persistent_term.erase(@token_cache_key)
    :persistent_term.erase(@source_cache_key)
    System.put_env("GITHUB_TOKEN", "preflight-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    AuthPreflight.invalidate(:test_setup)

    # A `default_request_fun` probe here asserts the transport outcome (a 401
    # clearing the memo). `/issues/{n}` reads are now cacheable (`:issue`,
    # #2352), and the read cache is a shared application child, so clear it so
    # the probe reaches the transport rather than a deposit from an earlier
    # test in the same partition.
    ReadCache.reset()

    on_exit(fn ->
      AuthPreflight.invalidate(:test_teardown)
      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(@token_cache_key)
        token -> :persistent_term.put(@token_cache_key, token)
      end

      case prev_source do
        :unset -> :persistent_term.erase(@source_cache_key)
        source -> :persistent_term.put(@source_cache_key, source)
      end
    end)

    :ok
  end

  describe "local budget hold wait-out (#2444)" do
    # #2444 acceptance 1: a `:local_hold` whose `reset_at` is a couple of
    # seconds out is waited out and the retry succeeds — preflight returns
    # `:ok`, so the workspace provisioning path never produces
    # `workspace_github_connectivity_failed` and the agent run survives. The
    # sleep is injected so the test asserts on the run surviving (a `:ok`
    # return) and on the wait actually happening (the sleep duration), not on
    # a log line and not on a real 2s wall-clock wait.
    test "a short local budget hold is waited out and the preflight succeeds" do
      parent = self()
      reset_at = DateTime.add(DateTime.utc_now(), 2, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      counter = start_counter()

      request_fun = fn request ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          {:error, {:aiur, :locally_held, hold}}
        else
          ok_response(request)
        end
      end

      sleep_fun = fn ms ->
        send(parent, {:sleep, ms})
        :ok
      end

      assert :ok =
               AuthPreflight.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end,
                 local_hold_sleep_fun: sleep_fun
               )

      # One held attempt, then a full successful retry (three checks).
      assert count(counter) == 4

      # The hold was 2s out, so the wait honours `reset_at` plus up to 500ms of
      # jitter — nothing more.
      assert_receive {:sleep, wait_ms}, 1000
      assert wait_ms >= 1_500 and wait_ms <= 2_500
      refute_receive {:sleep, _}, 100
    end

    # #2444 acceptance 2 (the mutation guard): a hold whose `reset_at` is
    # beyond the ceiling is a genuine capacity problem and still fails
    # preflight. Without this bound the wait-out fix is indistinguishable from
    # swallowing the error. The request_fun is called exactly once — no wait,
    # no retry — and the ordinary diagnostic is returned.
    test "a local budget hold beyond the ceiling still fails preflight without waiting" do
      parent = self()
      # Two minutes out — beyond the 60s default ceiling.
      reset_at = DateTime.add(DateTime.utc_now(), 120, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      counter = start_counter()

      request_fun = counting_request_fun(counter, fn _ -> {:error, {:aiur, :locally_held, hold}} end)
      sleep_fun = fn _ms -> send(parent, :slept) end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               AuthPreflight.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end,
                 local_hold_sleep_fun: sleep_fun
               )

      assert diagnostic.classification == :local_hold
      assert count(counter) == 1
      refute_receive :slept, 100
    end

    # #2444 acceptance 3: a pathologically re-armed hold (each wait produces a
    # fresh hold) terminates after the configured cap rather than pinning the
    # caller forever. Three waits by default, then the fourth attempt fails
    # closed.
    test "a repeatedly re-armed local hold terminates after the configured cap" do
      reset_at = DateTime.add(DateTime.utc_now(), 1, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      counter = start_counter()
      sleep_counter = start_counter()

      request_fun = counting_request_fun(counter, fn _ -> {:error, {:aiur, :locally_held, hold}} end)
      sleep_fun = fn _ms -> Agent.update(sleep_counter, &(&1 + 1)) end

      assert {:error, {:github_auth_preflight_failed, %{classification: :local_hold}}} =
               AuthPreflight.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end,
                 local_hold_sleep_fun: sleep_fun
               )

      # 3 waits + the final failing attempt; it never waits forever.
      assert count(counter) == 4
      assert count(sleep_counter) == 3
    end

    # #2444 acceptance 4: a hold whose `reset_at` has already passed by the
    # time the failure is produced (the daemon-restart burst) is retried
    # immediately — zero sleep — and succeeds, so the restart does not fail
    # the run for a hold that has already cleared.
    test "a local hold whose reset_at has passed is retried immediately and succeeds" do
      reset_at = DateTime.add(DateTime.utc_now(), -1, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}
      counter = start_counter()
      sleep_counter = start_counter()

      request_fun = fn request ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          {:error, {:aiur, :locally_held, hold}}
        else
          ok_response(request)
        end
      end

      sleep_fun = fn _ms -> Agent.update(sleep_counter, &(&1 + 1)) end

      assert :ok =
               AuthPreflight.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :not_installed} end,
                 local_hold_sleep_fun: sleep_fun
               )

      # One held attempt, then a full successful retry (three checks).
      assert count(counter) == 4
      # Nothing to wait for — `reset_at` already passed.
      assert count(sleep_counter) == 0
    end
  end
end
