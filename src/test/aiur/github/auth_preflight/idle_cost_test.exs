defmodule Aiur.GitHub.AuthPreflight.IdleCostTest do
  import Aiur.GitHub.AuthPreflight.TestFixtures

  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
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

  describe "ensure_preflight/1 — what an idle hour costs" do
    test "six idle poll cycles spend three requests in total, not eighteen" do
      counter = start_counter()
      opts = [request_fun: counting_request_fun(counter, &ok_response/1), gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      # Six cycles is one hour at the shipped idle cadence:
      # polling.interval_seconds 120 * polling.idle_widen_factor 5.0 = 600s.
      assert :ok = AuthPreflight.ensure_preflight(opts)
      assert count(counter) == 3

      for _cycle <- 2..6 do
        assert :ok = AuthPreflight.ensure_preflight(opts)
      end

      # 3 requests for the whole hour, of which /rate_limit is unbilled:
      # 2 billed for the hour rather than 12.
      assert count(counter) == 3
    end

    test "the unmemoized preflight_auth/1 still pays every time" do
      counter = start_counter()
      opts = [request_fun: counting_request_fun(counter, &ok_response/1), gh_auth_status_fun: fn -> {:ok, :not_installed} end]

      assert :ok = AuthPreflight.preflight_auth(opts)
      assert :ok = AuthPreflight.preflight_auth(opts)

      assert count(counter) == 6
    end

    test "a failed check is never memoized, so a broken credential is re-checked every cycle" do
      counter = start_counter()

      opts = [
        request_fun: counting_request_fun(counter, fn _ -> {:ok, %{status: 401, headers: [], body: %{}}} end),
        gh_auth_status_fun: fn -> {:ok, :not_installed} end
      ]

      assert {:error, {:github_auth_preflight_failed, _}} = AuthPreflight.ensure_preflight(opts)
      assert {:error, {:github_auth_preflight_failed, _}} = AuthPreflight.ensure_preflight(opts)

      assert count(counter) == 2
      refute AuthPreflight.memoized_identity()
    end
  end
end
