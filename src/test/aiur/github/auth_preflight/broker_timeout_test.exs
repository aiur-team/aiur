defmodule Aiur.GitHub.AuthPreflight.BrokerTimeoutTest do
  import Aiur.GitHub.AuthPreflight.TestFixtures

  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.GitHub.LocalHold
  alias Aiur.GitHub.ReadCache

  @token_cache_key {Aiur.GitHub.Config, :resolved_token}
  @source_cache_key {Aiur.GitHub.Config, :resolved_token_source}

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

  describe "budget broker timeout wait-out (#2457)" do
    # #2457 acceptance 1: a preflight that meets a budget broker timeout is
    # backed off and retried, so the run survives. `LocalHold.run/2` wraps the
    # whole three-check attempt; the first attempt's rate-limit check times out
    # at the broker (the `request_fun` returns the raw
    # `:github_budget_broker_timeout` transport error), and the retry succeeds —
    # preflight returns `:ok`, so the workspace provisioning path never
    # produces `workspace_github_connectivity_failed` and the agent run
    # survives. The sleep is injected so the assertion is on the run surviving,
    # not on a log line.
    test "a budget broker timeout is backed off and the preflight succeeds" do
      parent = self()
      counter = start_counter()

      request_fun = fn request ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          {:error, :github_budget_broker_timeout}
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

      # One timed-out attempt, then a full successful retry (three checks).
      assert count(counter) == 4

      # The first backoff is `backoff_base_ms` plus up to `jitter_ms`.
      assert_receive {:sleep, wait_ms}, 1000
      assert wait_ms >= LocalHold.backoff_base_ms()
      assert wait_ms <= LocalHold.backoff_base_ms() + LocalHold.jitter_ms()
      refute_receive {:sleep, _}, 100
    end

    # #2457 acceptance 3 at the preflight boundary: a persistently unreachable
    # broker fails closed — preflight still fails (after the capped retries),
    # so the run is terminated rather than the workspace being pinned forever.
    test "a persistently unreachable broker still fails preflight after the cap" do
      counter = start_counter()
      sleep_counter = start_counter()

      request_fun = counting_request_fun(counter, fn _ -> {:error, :github_budget_broker_timeout} end)
      sleep_fun = fn _ms -> Agent.update(sleep_counter, &(&1 + 1)) end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               AuthPreflight.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end,
                 local_hold_sleep_fun: sleep_fun
               )

      # Transient per the shared classifier; the diagnostic names the timeout.
      assert diagnostic.classification == :local_hold
      assert diagnostic.detail == %{reason: :github_budget_broker_timeout}
      assert AuthPreflight.local_hold_reason?({:github_auth_preflight_failed, diagnostic})
      assert diagnostic.message =~ "local budget broker"
      refute diagnostic.message =~ "raise the relevant"
      # `max_waits` waits + the final failing attempt; it never pins the caller.
      assert count(sleep_counter) == LocalHold.max_waits()
    end

    # #2457 acceptance 2: a malformed broker reply (broker unavailable) is
    # permanent and must still fail preflight on the first attempt — no
    # waiting, no retrying. Without this the "no failures" of the fix would be
    # indistinguishable from "errors swallowed".
    test "a permanent broker-unavailable still fails preflight without waiting" do
      counter = start_counter()

      request_fun = counting_request_fun(counter, fn _ -> {:error, :github_budget_broker_unavailable} end)
      sleep_fun = fn _ms -> flunk("must not sleep for a permanent broker fault") end

      assert {:error, {:github_auth_preflight_failed, diagnostic}} =
               AuthPreflight.preflight_auth(
                 request_fun: request_fun,
                 gh_auth_status_fun: fn -> {:ok, :available} end,
                 local_hold_sleep_fun: sleep_fun
               )

      # Exactly one attempt — the permanent fault is not retried.
      assert count(counter) == 1
      assert diagnostic.classification == :transport
      assert diagnostic.detail == %{reason: :github_budget_broker_unavailable}
    end
  end
end
