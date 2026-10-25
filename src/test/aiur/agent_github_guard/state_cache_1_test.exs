defmodule Aiur.AgentGitHubGuard.StateCache1Test do
  use Aiur.AgentGitHubGuardCase, async: true

  # ---------------------------------------------------------------------------
  # Shared GitHub state cache (#2073 U6)
  #
  # Sixteen agents asking about one pull request used to take sixteen leases and
  # pay sixteen times, because the broker rations spending but stores no answers.
  # These assert call COUNTS and BYTE EQUALITY, never latency or similarity: the
  # failure this design has to rule out is a cached response whose shape differs
  # subtly from the live one, which corrupts agent input without ever erroring.
  # ---------------------------------------------------------------------------

  describe "agent reads through the shared state cache" do
    test "two agents reading the same pull request produce one upstream call", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 1
    end

    test "a cached read is byte-identical to the uncached one", context do
      # A body carrying every byte a re-serialiser would quietly normalise: a
      # CR, a trailing space, and no final newline.
      output = ~S(line one <b> &\r\ntrailing space \nno-trailing-newline)
      # The fake `gh` short-circuits on a formatter flag before it reaches the
      # shared call log, so this shape is counted through its own log instead.
      formatted = Path.join(context.workspace, "formatted-calls")
      env = [FAKE_GH_FORMAT_OUTPUT: output, FAKE_GH_FORMAT_ARGS: formatted]

      assert {uncached, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body", "-q", ".body"], env)
      assert line_count(formatted) == 1

      assert {cached, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body", "-q", ".body"], env)
      assert line_count(formatted) == 1

      assert cached == uncached
      assert cached =~ "no-trailing-newline"
      refute String.ends_with?(cached, "\n")
    end

    test "different output shapes never share an entry", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body,title"])

      assert upstream_calls(context) == 2
    end

    test "a read whose output is a human table is not cached", context do
      # No `--json`: `gh` prints a terminal-width table with relative
      # timestamps, which is neither stable between two agents nor meaningful to
      # replay an hour later.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670"])

      assert upstream_calls(context) == 2
    end

    test "an unrecognised invocation falls through unchanged", context do
      assert {first, 0} = run_cached_guard(context, ["pr", "diff", "1670"])
      assert {second, 0} = run_cached_guard(context, ["pr", "diff", "1670"])

      assert first == second
      assert upstream_calls(context) == 2
    end

    test "a GraphQL query is never served from the store", context do
      # Its identity is an arbitrary document rather than a resource, so no
      # writer could ever invalidate the entry.
      assert {_, 0} = run_cached_guard(context, ["api", "graphql", "-f", "query=query{viewer{login}}"])
      assert {_, 0} = run_cached_guard(context, ["api", "graphql", "-f", "query=query{viewer{login}}"])

      assert upstream_calls(context) == 2
    end

    test "a resource number outside the third position is not guessed at", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "--json", "body", "1670"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "--json", "body", "1670"])

      assert upstream_calls(context) == 2
    end

    test "a missing store leaves every call behaving exactly as today", context do
      env = [AIUR_GITHUB_STATE_CACHE_ROOT: Path.join(context.workspace, "nonexistent/store")]

      assert {first, 0} = run_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert {second, 0} = run_guard(context, ["pr", "view", "1670", "--json", "body"], env)

      assert first == second
      assert upstream_calls(context) == 2
    end

    test "the kill switch disables the store outright", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_ENABLED: "0")
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_ENABLED: "0")

      assert upstream_calls(context) == 2
    end

    test "a caller demanding strict freshness always spends", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_BYPASS: "1")

      assert upstream_calls(context) == 2
    end

    test "a failed read is never stored", context do
      assert {_, 1} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], FAKE_GH_FAIL: "1")
      assert {_, 1} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], FAKE_GH_FAIL: "1")

      assert upstream_calls(context) == 2
    end

    test "a mutation retires the resource it changed", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1670", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      # Pull requests and issues share GitHub's number space, so a comment
      # posted through `gh issue comment` changes what `gh pr view` answers.
      assert upstream_calls(context) == 3
    end

    test "a mutation elsewhere leaves an unrelated entry alone", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["issue", "comment", "1671", "--body", "hi"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      assert upstream_calls(context) == 2
    end

    test "a daemon writer retires every cached shape of a resource", context do
      # The interlock with the free pipes: a webhook delivery or a mutation
      # write-through marks the resource, and the agent's next read pays.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 2
    end

    test "the repository is not guessed at from outside the workspace", context do
      outside = Path.join(context.workspace, "..") |> Path.expand() |> Path.join("elsewhere")
      File.mkdir_p!(outside)

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], [], cd: outside)
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], [], cd: outside)

      assert upstream_calls(context) == 2
    end

    test "an explicit --repo is authoritative anywhere", context do
      outside = Path.join(context.workspace, "..") |> Path.expand() |> Path.join("elsewhere-repo")
      File.mkdir_p!(outside)
      args = ["pr", "view", "1670", "-R", "other/thing", "--json", "body"]

      assert {_, 0} = run_cached_guard(context, args, [], cd: outside)
      assert {_, 0} = run_cached_guard(context, args, [], cd: outside)

      assert upstream_calls(context) == 1
    end

    test "ten identical reads spend once and report a ninety percent hit rate", context do
      args = ["pr", "view", "1670", "--json", "body"]

      outputs =
        for _read <- 1..10 do
          assert {output, 0} = run_cached_guard(context, args)
          output
        end

      assert Enum.uniq(outputs) |> length() == 1
      assert upstream_calls(context) == 1

      events = Path.join([context.state_path, "github-quota", "agent-cache.tsv"])

      rows =
        events
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))

      assert Enum.count(rows, &match?([_at, _consumer, "miss", "pr", "1670", "absent"], &1)) == 1
      assert Enum.count(rows, &match?([_at, _consumer, "store", "pr", "1670"], &1)) == 1
      assert Enum.count(rows, &match?([_at, _consumer, "hit", "pr", "1670"], &1)) == 9
    end

    test "multiple rotations retain one complete measurement window", context do
      args = ["pr", "view", "1670", "--json", "body"]
      assert {_, 0} = run_cached_guard(context, args)

      events = Path.join([context.state_path, "github-quota", "agent-cache.tsv"])
      row = "#{System.os_time(:second)}\tticket:1670\thit\tpr\t1670\n"
      oversized = String.duplicate(row, div(1_048_576, byte_size(row)) + 1)

      File.write!(events, oversized)
      assert {_, 0} = run_cached_guard(context, args)
      File.write!(events, oversized)
      assert {_, 0} = run_cached_guard(context, args)

      archives = Path.wildcard(events <> ".*")
      assert length(archives) == 2

      assert Enum.sum(
               Enum.map([events | archives], fn path ->
                 path |> File.read!() |> :binary.matches("\thit\t") |> length()
               end)
             ) > 50_000

      assert upstream_calls(context) == 1
    end

    test "miss rows classify every cache lookup failure", context do
      args = ["pr", "view", "1670", "--json", "body"]

      # No artifact exists yet.
      assert {_, 0} = run_cached_guard(context, args)
      [{_key, body}] = cached_shapes(context)
      meta = String.replace_suffix(body, ".body", ".meta")

      # A caller explicitly refusing replay.
      assert {_, 0} = run_cached_guard(context, args, AIUR_GITHUB_STATE_CACHE_BYPASS: "1")

      # An unreadable body and timestamp are both corrupt artifacts.
      File.chmod!(body, 0o000)
      assert {_, 0} = run_cached_guard(context, args)
      assert last_cache_miss_reason(context) == "corrupt"

      File.write!(meta, "not-a-timestamp\n")
      assert {_, 0} = run_cached_guard(context, args)

      # Future timestamp and timestamp outside the TTL have distinct causes.
      File.write!(meta, "#{System.os_time(:second) + 60}\n")
      assert {_, 0} = run_cached_guard(context, args)
      File.write!(meta, "1\n")
      assert {_, 0} = run_cached_guard(context, args)

      # A stamp that survived while its body vanished is a torn entry — the
      # store was pruned or a partial write removed the body. It is a distinct
      # cause from `absent` (nothing was ever stored) and from `corrupt`
      # (present but unreadable).
      File.rm!(body)
      assert {_, 0} = run_cached_guard(context, args)
      assert last_cache_miss_reason(context) == "torn"

      # A daemon-side resource retirement is the final independent cause.
      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))
      assert {_, 0} = run_cached_guard(context, args)

      reasons =
        Path.join([context.state_path, "github-quota", "agent-cache.tsv"])
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.filter(&(Enum.at(&1, 2) == "miss"))
        |> Enum.map(&Enum.at(&1, 5))
        |> MapSet.new()

      assert reasons == MapSet.new(~w(absent bypassed corrupt torn clock-skewed expired invalidated))
    end

    test "a stale entry's miss is classified as expired rather than absent", context do
      # A fresh read writes a store row; aging the entry past the window makes
      # the next read miss because the answer is too old to replay, not because
      # nothing was ever cached.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 1

      [{_shape, body}] = cached_shapes(context)
      meta = String.replace_suffix(body, ".body", ".meta")
      File.write!(meta, "#{DateTime.to_unix(DateTime.utc_now()) - 3600}\n")

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      assert upstream_calls(context) == 2

      rows =
        Path.join([context.state_path, "github-quota", "agent-cache.tsv"])
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t"))

      assert Enum.any?(rows, &match?([_at, _consumer, "miss", "pr", "1670", "absent"], &1))
      assert Enum.any?(rows, &match?([_at, _consumer, "miss", "pr", "1670", "expired"], &1))
    end

    # -------------------------------------------------------------------------
    # Coalescing. A stored answer only removes the reads that come AFTER one; it
    # can do nothing about the reads that arrive together, which all miss and all
    # pay. These are therefore run genuinely concurrently — a sequential version
    # of the same assertion would pass on caching alone and prove nothing about
    # the mechanism under test.
    # -------------------------------------------------------------------------

    test "thirteen simultaneous readers of one pull request produce one upstream call", context do
      args = ["pr", "view", "1670", "--json", "body"]
      results = concurrent_reads(context, args, 13)

      assert Enum.all?(results, &match?({_output, 0}, &1))
      assert upstream_calls(context) == 1

      # One call means twelve of these were replayed, so byte equality is the
      # claim that matters: a follower must be given the leader's answer, not an
      # approximation of it.
      assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1

      # And they were replayed by the mechanism this test names. The wrapper
      # records a waiting follower as `coalesced` and a plain later reader as
      # `hit`, so without this the same call count would also be produced by
      # readers that happened to be serialised into a queue and found a stored
      # answer — caching, which is a different mechanism with a different bound.
      assert cache_events(context, "coalesced") > 0
      assert cache_events(context, "coalesced") + cache_events(context, "hit") == 12
    end

    test "simultaneous readers of different resources are not made to wait on each other", context do
      # The claim is per resource shape. Two agents reading two pull requests are
      # not duplicates and must both be admitted.
      warm_cache_broker(context)

      results =
        [["pr", "view", "1670", "--json", "body"], ["pr", "view", "1671", "--json", "body"]]
        |> Task.async_stream(&run_cached_guard(context, &1, broker_env(context) ++ [FAKE_GH_SLEEP: "1"]),
          max_concurrency: 2,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({_output, 0}, &1))
      assert upstream_calls(context) == 2
    end

    test "a leader that never answers costs one duplicate call, never a stall", context do
      # A claim taken by a process that dies before writing anything. The follower
      # waits out its patience and then fetches for itself, which is the pre-store
      # behaviour rather than a hang.
      key = broker_token_key()
      broker = AgentGitHubGuard.budget_broker_path(context.workspace)
      database = Path.join(cache_state_dir(context), "budget.sqlite3")
      File.mkdir_p!(cache_state_dir(context))

      assert {_output, 0} =
               run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], AIUR_GITHUB_STATE_CACHE_WAIT_MS: "300")

      # A claim on the exact shape the read below computes, held by a lease
      # nothing will ever release.
      [{shape, _entry}] = cached_shapes(context)

      {_output, 0} =
        System.cmd("python3", [
          broker,
          "acquire",
          "--db",
          database,
          "--token-key",
          key,
          "--resource",
          "core",
          "--consumer-key",
          "abandoned",
          "--endpoint-family",
          "pulls",
          "--max-inflight",
          "4",
          "--max-inflight-per-endpoint",
          "2",
          "--requests-per-minute",
          "120",
          "--stagger-ms",
          "0",
          "--lease-ttl-ms",
          "600000",
          "--cache-key",
          shape,
          "--cache-claim-ttl-ms",
          "600000"
        ])

      # Retire the answer so the follower cannot simply be served the entry.
      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_output, 0} =
               run_cached_guard(
                 context,
                 ["pr", "view", "1670", "--json", "body"],
                 broker_env(context) ++ [AIUR_GITHUB_STATE_CACHE_WAIT_MS: "300"]
               )

      assert upstream_calls(context) == 2
    end

    test "a REST read of an issue is filed under that issue", context do
      # The join with the daemon's writers. `gh api repos/owner/repo/issues/1670`
      # and `gh issue view 1670` are the same resource; filed under a digest of the
      # URL instead, the first would survive a writer retiring the second. Pull
      # requests are exercised separately: their REST resource is a merge
      # verdict and is refused outright (see the REST verdict test), so the
      # identity join is proven on the issue resource, which is still cacheable.
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670"])
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate("owner/repo", 1670, state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/issues/1670"])
      assert upstream_calls(context) == 2
    end

    test "a REST read naming no single resource is retired by any write in the repository", context do
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/labels"])
      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/labels"])
      assert upstream_calls(context) == 1

      assert :ok = AgentCache.invalidate_collections("owner/repo", state_dir: cache_state_dir(context))

      assert {_, 0} = run_cached_guard(context, ["api", "repos/owner/repo/labels"])
      assert upstream_calls(context) == 2
    end

    # The trap this pair exists for: an Elixir writer and a shell reader that
    # disagree on where a resource lives give a cache that is always cold and
    # always looks healthy. So the identity is asserted from both ends against the
    # SAME resource — the directory the shell actually created, and the path the
    # Elixir side derives from `ResourceStore.key/4`.
    test "the daemon and the wrapper agree on where a resource lives", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])

      [{shape, body}] = cached_shapes(context)
      assert shape =~ ~r/\Aowner\/repo\/pr\/1670\/[0-9a-f]{64}\z/

      key = ResourceStore.key(:pull_request, "owner", "repo", 1670)

      assert AgentCache.resource_dir(key, state_dir: cache_state_dir(context)) ==
               Path.dirname(body)
    end

    test "a resource the daemon spells differently still resolves to one place", context do
      # `ResourceStore.key/4` down-cases owner and repo because the pipes disagree
      # on casing. The wrapper's directories are the same identity, so the store's
      # spelling must land on them.
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"])
      [{_shape, body}] = cached_shapes(context)

      key = ResourceStore.key(:pull_request, "OWNER", "Repo", "1670")

      assert AgentCache.resource_dir(key, state_dir: cache_state_dir(context)) ==
               Path.dirname(body)
    end

    # The freshness window is the only thing standing between a kept answer and a
    # wrong one for everything the daemon does not hear about, so it gets asserted
    # rather than assumed. Without this an entry could be kept for a month and
    # every other test in this block would still pass.
    test "an answer is not served once its window has closed", context do
      env = [AIUR_GITHUB_STATE_CACHE_TTL_MS: "1000"]

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert upstream_calls(context) == 1

      # Past the window. Entry stamps are whole seconds, so the wait is two.
      Process.sleep(2_100)

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert upstream_calls(context) == 2
    end

    test "a window below the resolution of an entry stamp keeps nothing", context do
      env = [AIUR_GITHUB_STATE_CACHE_TTL_MS: "500"]

      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)
      assert {_, 0} = run_cached_guard(context, ["pr", "view", "1670", "--json", "body"], env)

      assert upstream_calls(context) == 2
    end

    # R10. These reads decide whether to merge and whether CI passed. They cannot
    # be repaired after the fact and nothing invalidates them — a `git push` and a
    # completing check run never pass through this wrapper — so they are refused
    # outright rather than given a short window.
    test "a CI verdict is never served from the store", context do
      assert {_, 0} = run_cached_guard(context, ["pr", "checks", "1670", "--json", "name,state"])
      assert {_, 0} = run_cached_guard(context, ["pr", "checks", "1670", "--json", "name,state"])

      assert upstream_calls(context) == 2
    end
  end
end
