defmodule Aiur.AgentGitHubGuard.StateCache2Test do
  use Aiur.AgentGitHubGuardCase, async: true

  describe "agent reads through the shared state cache" do
    test "a merge decision is never served from the store", context do
      for fields <- ["statusCheckRollup", "mergeable,mergeStateStatus", "body,state", "reviewDecision"] do
        File.rm(context.calls)

        assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", fields])
        assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", fields])

        assert upstream_calls(context) == 2, "#{fields} was served from the store"
      end
    end

    test "REST verdict and merge-gating reads are never served from the store", context do
      endpoints = [
        "repos/owner/repo/commits/deadbeef/check-runs",
        "repos/owner/repo/commits/deadbeef/check-suites",
        "repos/owner/repo/commits/deadbeef/status",
        "repos/owner/repo/statuses/main",
        "repos/owner/repo/pulls/1670",
        "repos/owner/repo/pulls/1670/merge",
        "repos/owner/repo/pulls/1670/requested_reviewers",
        "repos/owner/repo/pulls/1670/reviews",
        "repos/owner/repo/actions/runs"
      ]

      for endpoint <- endpoints do
        File.rm(context.calls)

        assert {_, 0} = run_cached_guard(context, ["api", endpoint])
        assert {_, 0} = run_cached_guard(context, ["api", endpoint])

        assert upstream_calls(context) == 2, "#{endpoint} was served from the store"
      end

      assert cache_events(context, "hit") == 0
      assert cache_events(context, "miss") == 0
      assert cached_shapes(context) == []
    end

    test "stable Actions workflow metadata is still shared", context do
      endpoint = "repos/owner/repo/actions/workflows"

      assert {_, 0} = run_cached_guard(context, ["api", endpoint])
      assert {_, 0} = run_cached_guard(context, ["api", endpoint])

      assert upstream_calls(context) == 1
      assert cache_events(context, "miss") == 1
      assert cache_events(context, "hit") == 1
    end

    test "a field set carrying no verdict is still shared", context do
      # The exclusion must be the named fields, not `--json` in general.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body,title,author"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body,title,author"])

      assert upstream_calls(context) == 1
    end

    test "two credentials never share one answer", context do
      first = [AIUR_GITHUB_BUDGET_KEY: "c" <> String.duplicate("0", 63)]
      second = [AIUR_GITHUB_BUDGET_KEY: "d" <> String.duplicate("0", 63)]
      args = ["pr", "view", "1670", "--json", "body"]

      assert {_, 0} = run_cached_guard(context, args, broker_env(context) ++ first)
      assert {_, 0} = run_cached_guard(context, args, broker_env(context) ++ second)

      # A response body is identity-dependent — a private repository one token
      # cannot see, a `permissions` object, a collaborator list.
      assert upstream_calls(context) == 2
    end

    test "editing a comment does not flush the whole repository", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1671", "--json", "body"])
      assert upstream_calls(context) == 2

      # How an agent updates its workpad. The comment id is not a ticket number,
      # so the resource it belongs to cannot be named — but agents do this every
      # few minutes, and retiring the repository for it would flush the store
      # continuously and the sharing would never happen.
      assert {_, 0} =
               run_cached_guard(context, [
                 "api",
                 "-X",
                 "PATCH",
                 "repos/owner/repo/issues/comments/99001",
                 "-f",
                 "body=updated"
               ])

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1671", "--json", "body"])

      assert upstream_calls(context) == 3
    end

    test "an agent that opts out of reading still retires what it changes", context do
      # The store is shared by the whole host. One process declining to read from
      # it must not leave every other agent replaying an answer it just replaced.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 1

      assert {_, 0} =
               run_cached_guard(context, ["issue", "comment", "1670", "--body", "hi"], AIUR_GITHUB_STATE_CACHE_ENABLED: "0")

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 3
    end

    test "a write against another GitHub deployment retires nothing here", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1670", "--hostname", "ghe.example.com", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 2
    end

    test "naming the default host explicitly is not another deployment", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1670", "--hostname", "github.com", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 3
    end

    test "a REST read with a query string is still filed under its resource", context do
      # Pull requests are a refused verdict resource (see the REST verdict test),
      # so the query-string identity rule is exercised on the issue resource,
      # which is still cacheable.
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670?per_page=1"])
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670?per_page=1"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670?per_page=1"])
      assert upstream_calls(context) == 2
    end

    test "a body that vanished before lookup falls through and is recorded as torn", context do
      # The original hazard this pair guards: the store's prune (`cache_prune`,
      # `-mmin +120 -delete` on `*.body` and `*.meta`) or a partial disk-full
      # write can leave a meta behind while its body is gone. That is a torn
      # entry, not a cold read — it must fall through to the real `gh` (never
      # answer with nothing) and be recorded as `torn`, so the dashboard shows a
      # store-integrity failure instead of a wall of `absent` that reads as a
      # cold cache with diverse shapes.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      [{_shape, body}] = cached_shapes(context)

      File.rm!(body)

      assert {output, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert output != ""
      assert upstream_calls(context) == 2
      assert last_cache_miss_reason(context) == "torn"
    end

    test "a body vanishing after lookup is fetched and recorded as corrupt", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      [{_shape, body}] = cached_shapes(context)

      real_cat = System.find_executable("cat") || flunk("cat is required")
      fake_cat = Path.join(Path.dirname(context.fake_gh), "cat")

      File.write!(
        fake_cat,
        """
        #!/bin/sh
        if [ -n "${FAKE_CAT_VANISH:-}" ]; then
          case "${1:-}" in *.body) rm -f -- "$1" ;; esac
        fi
        exec "#{real_cat}" "$@"
        """
      )

      File.chmod!(fake_cat, 0o755)

      env = [
        FAKE_CAT_VANISH: body,
        PATH: "#{Path.dirname(context.fake_gh)}:#{System.get_env("PATH")}"
      ]

      assert {output, 0} =
               run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)

      assert output != ""
      assert upstream_calls(context) == 2
      assert last_cache_miss_reason(context) == "corrupt"
    end

    test "the merge gate still refuses with the store enabled", context do
      assert {output, 77} = run_cached_guard(context, ["pr", "merge", "1670", "--squash"])

      assert output =~ "agents cannot approve or merge pull requests"
      refute File.exists?(context.calls)
    end

    test "the dispatch-disposition gate still refuses with the store enabled", context do
      assert {output, 78} = run_cached_guard(context, ["issue", "create", "--title", "t", "--body", "b"])

      assert output =~ "no dispatch disposition"
      refute File.exists?(context.calls)
    end

    # #2307 agent conditional reads. A stored ETag turns an expired re-fetch
    # into an If-None-Match request, so an unchanged answer comes back 304 and
    # is reconciled free instead of billed again. The validator is only sent
    # while a body is held (a 304 with no body would spend a request and learn
    # nothing), and a 304 answers from the cache rather than the empty body.
    test "a 200 gh api read stores the response ETag for a later conditional re-read", context do
      env = [
        AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_HEADERS: "HTTP/2 200\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n",
        FAKE_GH_BODY: "cached-v1\n"
      ]

      assert {"cached-v1\n", 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670"], env)

      [{_key, body}] = cached_shapes(context)
      meta = String.replace_suffix(body, ".body", ".meta")
      assert File.read!(meta) =~ "\n\"v1\""
    end

    test "a conditional re-fetch sends If-None-Match and a 304 answers from the cache, free", context do
      budget_root = Path.join(context.state_path, "host-budget")
      broker = AgentGitHubGuard.budget_broker_path(context.workspace)
      key = "a" <> String.duplicate("0", 63)
      args = ["api", "repos/owner/repo/issues/1670"]
      args_file = Path.join(context.workspace, "args")
      headers200 = "HTTP/2 200\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
      headers304 = "HTTP/2 304\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"

      base_env = [
        AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_ARGS: args_file,
        AIUR_GITHUB_BUDGET_ROOT: budget_root,
        AIUR_GITHUB_BUDGET_KEY: key,
        AIUR_GITHUB_BUDGET_BROKER: broker,
        AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "10"
      ]

      # Run 1: 200 with an ETag; the exact bytes are cached.
      assert {"cached-v1\n", 0} = run_guard(context, args, base_env ++ [FAKE_GH_HEADERS: headers200, FAKE_GH_BODY: "cached-v1\n"])

      # Nothing stored yet, so no validator was sent.
      refute File.read!(args_file) =~ "If-None-Match"

      # Past the freshness window, the stored ETag makes the re-fetch
      # conditional. The mock now mimics real gh: exit 1 + `gh: HTTP 304` on
      # stderr, which the guard must turn into a served 304 (exit 0, cached
      # body, suppressed stderr, reconciled free).
      Process.sleep(2_100)
      File.rm(args_file)

      assert {"cached-v1\n", 0} =
               run_guard(context, args, base_env ++ [FAKE_GH_HEADERS: headers304, FAKE_GH_BODY: "stale-304\n", FAKE_GH_304_ERROR: "1"])

      assert File.read!(args_file) =~ "If-None-Match: \"v1\""

      # The 304 admission was reconciled free; the 200 before it was billable.
      assert {snapshot, 0} =
               System.cmd("python3", [broker, "snapshot", "--db", Path.join(budget_root, "budget.sqlite3"), "--token-key", key])

      assert snapshot
             |> Jason.decode!()
             |> Map.fetch!("admissions")
             |> Enum.map(& &1["billable"])
             |> Enum.sort() == [false, true]
    end

    # A served 304 carries no body, so the answer for an `--include` caller must
    # be the cached include-shaped bytes (headers AND body) — never the bare 304
    # status line the response actually carried, which would silently drop the
    # body. The cache-hit path already serves the same entry unchanged to any
    # caller, so the 304 path must not answer differently for the same command.
    test "a 304 answers an --include caller with the full cached headers+body, not bare 304 headers", context do
      args = ["api", "repos/owner/repo/issues/1670", "--include"]
      args_file = Path.join(context.workspace, "args")
      headers200 = "HTTP/2 200\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
      headers304 = "HTTP/2 304\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
      include_body = headers200 <> "cached-v1\n"

      env = [
        AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_ARGS: args_file
      ]

      # Run 1: a 200 --include read stores the include-shaped bytes exactly as
      # the caller saw them (headers + body).
      assert {^include_body, 0} =
               run_cached_guard(context, args, env ++ [FAKE_GH_HEADERS: headers200, FAKE_GH_BODY: "cached-v1\n"])

      Process.sleep(2_100)
      File.rm(args_file)

      # Run 2: the expired conditional re-fetch answers 304. The --include caller
      # must be served the full include-shaped cached body — not the bare 304
      # status line (which has no body).
      assert {^include_body, 0} =
               run_cached_guard(context, args, env ++ [FAKE_GH_HEADERS: headers304, FAKE_GH_BODY: "stale-304\n", FAKE_GH_304_ERROR: "1"])

      assert File.read!(args_file) =~ "If-None-Match: \"v1\""

      # The 304 carried no body, so the good include-shaped body must still be
      # what the store holds — a header-only 304 must never be re-stored over it.
      [{_key, body}] = cached_shapes(context)
      assert File.read!(body) == include_body
    end

    # A served 304 confirms the held body is current, so the fetched-at stamp is
    # refreshed. Without that refresh the entry would stay permanently expired
    # and every subsequent read would re-fetch (paying a lease, an admission and
    # a round trip) to re-learn the same 304.
    test "a 304 refreshes the entry stamp so the next read is served from the cache", context do
      args = ["api", "repos/owner/repo/issues/1670"]
      args_file = Path.join(context.workspace, "args")
      headers200 = "HTTP/2 200\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"
      headers304 = "HTTP/2 304\netag: \"v1\"\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n"

      env = [
        AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_ARGS: args_file
      ]

      # Run 1: 200, cached.
      assert {"cached-v1\n", 0} =
               run_cached_guard(context, args, env ++ [FAKE_GH_HEADERS: headers200, FAKE_GH_BODY: "cached-v1\n"])

      Process.sleep(2_100)
      File.rm(args_file)

      # Run 2: the expired conditional re-fetch answers 304 and refreshes the
      # fetched-at stamp.
      assert {"cached-v1\n", 0} =
               run_cached_guard(context, args, env ++ [FAKE_GH_HEADERS: headers304, FAKE_GH_BODY: "stale-304\n", FAKE_GH_304_ERROR: "1"])

      assert File.read!(args_file) =~ "If-None-Match: \"v1\""
      calls_after_304 = upstream_calls(context)

      # Run 3 (well inside the refreshed window): served from the cache as a
      # fresh hit — no new upstream call, no validator sent. Without the stamp
      # refresh the entry would still be expired and run 3 would re-fetch.
      File.rm(args_file)

      assert {"cached-v1\n", 0} =
               run_cached_guard(context, args, env ++ [FAKE_GH_HEADERS: headers200, FAKE_GH_BODY: "stale-again\n"])

      assert upstream_calls(context) == calls_after_304
      refute File.exists?(args_file)
    end

    test "a re-fetch with no stored ETag sends no validator", context do
      budget_root = Path.join(context.state_path, "host-budget")
      broker = AgentGitHubGuard.budget_broker_path(context.workspace)
      key = "a" <> String.duplicate("0", 63)
      args = ["api", "repos/owner/repo/issues/1670"]
      args_file = Path.join(context.workspace, "args")

      env = [
        AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_ARGS: args_file,
        # No etag header: the server did not issue a validator.
        FAKE_GH_HEADERS: "HTTP/2 200\nX-RateLimit-Resource: core\nX-RateLimit-Limit: 5000\nX-RateLimit-Remaining: 4999\n\n",
        AIUR_GITHUB_BUDGET_ROOT: budget_root,
        AIUR_GITHUB_BUDGET_KEY: key,
        AIUR_GITHUB_BUDGET_BROKER: broker,
        AIUR_GITHUB_CORE_LIMIT_PER_HOUR: "10"
      ]

      assert {"ok\n", 0} = run_guard(context, args, env)
      Process.sleep(2_100)
      File.rm(args_file)
      assert {"ok\n", 0} = run_guard(context, args, env)

      # Without a held ETag there is nothing to validate against, so the read
      # stays unconditional (and billed).
      refute File.read!(args_file) =~ "If-None-Match"
    end

    test "a 200 refresh replaces both the cached body and the stored ETag", context do
      args_file = Path.join(context.workspace, "args")

      env = [
        AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000",
        FAKE_GH_INCLUDE_HEADERS: "1",
        FAKE_GH_ARGS: args_file
      ]

      assert {"cached-v1\n", 0} =
               run_cached_guard(context, ["api", "repos/owner/repo/issues/1670"], env ++ [FAKE_GH_HEADERS: "HTTP/2 200\netag: \"v1\"\n\n", FAKE_GH_BODY: "cached-v1\n"])

      Process.sleep(2_100)
      File.rm(args_file)

      assert {"cached-v2\n", 0} =
               run_cached_guard(context, ["api", "repos/owner/repo/issues/1670"], env ++ [FAKE_GH_HEADERS: "HTTP/2 200\netag: \"v2\"\n\n", FAKE_GH_BODY: "cached-v2\n"])

      # The re-fetch validated against the OLD etag, and the 200 replaced it.
      assert File.read!(args_file) =~ "If-None-Match: \"v1\""
      [{_key, body}] = cached_shapes(context)
      meta = String.replace_suffix(body, ".body", ".meta")
      assert File.read!(meta) =~ "\n\"v2\""
    end
  end
end
