defmodule Aiur.AgentGitHubGuard.LedgerAndCredentialsTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "records ticket-shaped read and write attribution without command arguments", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--body", "secret body"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    # `issue view` is GraphQL on the wire and `issue edit` a core write; the
    # fifth column names the gh subcommand that made each call. The credential
    # fingerprint and wrapper pid follow it, so match up to the next tab.
    assert events =~ "\tticket:1670\tread\tgraphql\tissue view\t"
    assert events =~ "\tticket:1670\twrite\tcore\tissue edit\t"
    refute events =~ "secret body"
  end

  # GraphQL is billed in points against its own budget. A row that does not say
  # which budget it spent gets counted against core, putting agent GraphQL
  # traffic in the wrong window (#1805).
  test "names the budget each recorded call was billed to", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    # REST `gh api` reads normalise their call site to `api` rather than one
    # row per endpoint URL. The credential fingerprint and wrapper pid follow
    # the call site, so match up to the next tab.
    assert events =~ "\tread\tgraphql\tapi graphql\t"
    assert events =~ "\tread\tcore\tapi\t"
  end

  # `gh pr view/list/status/checks` and `gh issue view/list/status` go through
  # GitHub's GraphQL endpoint on the wire, so they bill the credential's
  # GraphQL window, not core (#2299). The descriptive family stays
  # pulls/issues — the broker's lease pool and audit histogram must not collapse
  # onto `graphql` — while `resource` carries the accounting bucket (#2299
  # review).
  test "files GraphQL-on-the-wire gh commands against the GraphQL budget", context do
    graphql_commands = [
      ["pr", "view", "1670"],
      ["pr", "list", "--json", "number"],
      ["pr", "status"],
      ["pr", "checks", "1670"],
      ["issue", "view", "1670"],
      ["issue", "list", "--json", "number"],
      ["issue", "status"]
    ]

    Enum.each(graphql_commands, fn command ->
      assert {"ok\n", 0} = run_guard(context, command)
    end)

    assert {"ok\n", 0} = run_guard(context, ["pr", "diff", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["search", "issues", "repo:owner/repo"])
    assert {"ok\n", 0} = run_guard(context, ["search", "repos", "owner"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))

    # Each row names the gh subcommand as its call site; the credential
    # fingerprint and wrapper pid ride after it, so match up to the next tab.
    Enum.each(graphql_commands, fn [_name, _sub | _] = command ->
      call_site = Enum.take(command, 2) |> Enum.join(" ")
      assert events =~ "\tread\tgraphql\t#{call_site}\t"
    end)

    # `pr diff` is REST and stays a core pull.
    assert events =~ "\tread\tcore\tpr diff\t"
    # `gh search issues` is GraphQL on the wire; `gh search repos` hits the
    # REST /search/* endpoint and books to the separate `search` pool.
    assert events =~ "\tread\tgraphql\tsearch issues\t"
    assert events =~ "\tread\tsearch\tsearch repos\t"
  end

  # `gh search` is split because its subcommands use different transports and
  # different GitHub windows: issues/prs are GraphQL, repos/code/commits/users
  # hit REST /search/* and are metered against the separate ~30/min search pool.
  # Booking the two to one bucket — core or graphql — would pace nothing against
  # the pool that actually throttles first (#2299 review).
  test "splits gh search by subcommand across the graphql and search pools", context do
    search_commands = [
      {["search", "issues", "state:open"], "graphql"},
      {["search", "prs", "state:open"], "graphql"},
      {["search", "repos", "owner"], "search"},
      {["search", "code", "query"], "search"},
      {["search", "commits", "query"], "search"},
      {["search", "users", "owner"], "search"}
    ]

    Enum.each(search_commands, fn {command, _resource} ->
      assert {"ok\n", 0} = run_guard(context, command), "admission failed for #{inspect(command)}"
    end)

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))

    Enum.each(search_commands, fn {[name, sub | _], resource} ->
      assert events =~ "\tread\t#{resource}\t#{name} #{sub}\t"
    end)
  end

  # The `pr`/`issue` write subcommands are a GraphQL/REST mix (#2297):
  # `pr create|merge|review` and `issue create` mutate through GraphQL, while
  # the rest are REST and keep the pulls/issues families.
  test "files the GraphQL write subcommands against the GraphQL budget", context do
    assert {"ok\n", 0} = run_guard(context, ["pr", "create", "--title", "x"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "review", "7", "--comment", "--body", "looks reasonable"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "create", "--title", "x", "--label", "agent:todo"])
    assert {"ok\n", 0} = run_guard(context, ["pr", "close", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--body", "x"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))

    assert events =~ "\twrite\tgraphql\tpr create\t"
    assert events =~ "\twrite\tgraphql\tpr review\t"
    assert events =~ "\twrite\tgraphql\tissue create\t"
    assert events =~ "\twrite\tcore\tpr close\t"
    assert events =~ "\twrite\tcore\tissue edit\t"
  end

  # The call-site column must never carry raw argv: a crafted second positional
  # would otherwise write a second forged spend row into the TSV attributed to
  # another ticket. Both positionals are bounded to the safe set and the
  # subcommand is allowlisted, so an injection collapses to the bare command
  # name and the forged row never appears (#2299 review).
  test "a crafted call-site argument cannot inject a spend row", context do
    # `subcommand_name` carries a newline + forged TSV row. If it reached the
    # file verbatim the guard would write two lines and the forged one would
    # satisfy the reader's validated fields. Because the forged second
    # positional is not the literal `view`, the classification falls through to
    # the generic `pr` write arm — which still must not leak the raw value into
    # the stored call site.
    forged = "view\n#{DateTime.to_unix(DateTime.utc_now())}\tticket:9999\tread\tcore\tapi"
    assert {"ok\n", 0} = run_guard(context, ["pr", forged, "1670"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    rows = events |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))

    # The forged row is absent; the real call is recorded once, with the bare
    # command name (the injected subcommand is not allowlisted) and none of the
    # forged content on the line. The call site is the fifth column; the
    # fingerprint and pid follow it.
    assert length(rows) == 1
    refute Enum.any?(rows, &match?([_at, "ticket:9999", "read", "core", "api"], &1))
    refute events =~ "ticket:9999"
    assert Enum.any?(rows, &match?([_at, _consumer, _direction, _resource, "pr" | _], &1))
  end

  # A call site the allowlist does not yet enumerate must still be attributed.
  # gh grows subcommands, and Aiur grows call sites, so the interesting case is
  # not the ones listed above — it is the next one. The column degrades to the
  # bare command name rather than to an `unknown` bucket, so a new subcommand
  # is ranked one level coarser instead of vanishing from the breakdown, and a
  # brand-new top-level command still names itself (#2299).
  test "an unrecognised call site degrades to the command name, not an unknown bucket", context do
    # `pr` is allowlisted but `sync` is not: the call site keeps the command.
    assert {"ok\n", 0} = run_guard(context, ["pr", "sync", "1670"])
    # A top-level command the classification does not enumerate at all.
    assert {"ok\n", 0} = run_guard(context, ["cache", "list"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    call_sites = events |> String.split("\n", trim: true) |> Enum.map(&(String.split(&1, "\t") |> Enum.at(4)))

    assert "pr" in call_sites
    assert "cache" in call_sites
    refute "unknown" in call_sites
    refute Enum.any?(call_sites, &(&1 in ["", nil]))
  end

  # The agent-side record now carries the credential fingerprint (never the
  # token) and the wrapper pid, so a request is attributable to its ticket's
  # pool and to the exact subprocess that made it without a live /proc sweep
  # (#2255). The call-site column sits between the resource and the fingerprint.
  test "records a credential-fingerprint and pid column on every agent request", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    [row | _] = String.split(events, "\n", trim: true)
    [_unix, "ticket:1670", "read", "graphql", call_site, token_key, pid] = String.split(row, "\t")

    # The call site names the subcommand; budget is disabled in this harness, so
    # the fingerprint column is blank (never a refused call) while the pid names
    # the wrapper subprocess.
    assert call_site == "issue view"
    assert token_key == ""
    assert pid =~ ~r/^\d+$/
  end

  test "carries the configured credential fingerprint into the agent request record", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"], AIUR_GITHUB_BUDGET_KEY: "fingerprint-abc")

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tread\tgraphql\tissue view\tfingerprint-abc\t"
  end

  # #2356: the agent environment carries no GITHUB_TOKEN/GH_TOKEN — the guard
  # reads the credential from the file the daemon wrote and injects it ONLY
  # into the real `gh` child of the governed call. A bare curl or a dependency
  # build script never sees it.
  test "governed gh injects the token-file credential only into the real gh child", context do
    token_file = Path.join(context.state_path, "agent-token")
    observed = Path.join(context.state_path, "observed-token-env")
    custom_gh = Path.join(context.state_path, "custom-gh")
    File.mkdir_p!(context.state_path)

    File.write!(token_file, "file-credential\n")
    File.mkdir_p!(Path.dirname(custom_gh))

    File.write!(custom_gh, """
    #!/bin/sh
    printf 'GH_TOKEN=%s\\nGITHUB_TOKEN=%s\\n' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" > #{observed}
    printf 'ok\\n'
    """)

    File.chmod!(custom_gh, 0o755)

    env =
      Enum.map(guard_env(context), fn
        {"AIUR_REAL_GH", _} -> {"AIUR_REAL_GH", custom_gh}
        {"AIUR_GITHUB_CREDENTIAL_FILE", _} -> {"AIUR_GITHUB_CREDENTIAL_FILE", token_file}
        entry -> entry
      end)

    assert {"ok\n", 0} = run_agent_guard(context, ["api", "repos/owner/repo/issues/2356"], env)
    assert File.read!(observed) == "GH_TOKEN=file-credential\nGITHUB_TOKEN=\n"
  end

  # #2356 acceptance: a governed `gh` call with the credential supplied ONLY
  # through the token file still succeeds AND records an admission under the
  # credential's own budget key — no environment token involved.
  test "a governed call with a token-file-only credential records an admission", context do
    budget_root = Path.join(context.state_path, "token-budget")
    broker = AgentGitHubGuard.budget_broker_path(context.workspace)
    token_file = Path.join(context.state_path, "agent-token")
    File.mkdir_p!(context.state_path)
    File.write!(token_file, "file-credential\n")

    identity_key = Budget.identity_key("machine_user:primary:aiur-bot")
    key = Budget.token_key("file-credential")

    assert {"ok\n", 0} =
             run_guard(context, ["api", "repos/owner/repo/issues/2356"],
               AIUR_GITHUB_CREDENTIAL_FILE: token_file,
               AIUR_GITHUB_BUDGET_ROOT: budget_root,
               AIUR_GITHUB_BUDGET_BROKER: broker,
               AIUR_GITHUB_BUDGET_IDENTITY_KEY: identity_key,
               AIUR_GITHUB_STAGGER_MS: "0"
             )

    assert {snapshot, 0} =
             System.cmd("python3", [
               broker,
               "snapshot",
               "--db",
               Path.join(budget_root, "budget.sqlite3"),
               "--token-key",
               key,
               "--identity-key",
               identity_key
             ])

    assert length(Jason.decode!(snapshot)["admissions"]) == 1

    # The agent request record carries the credential fingerprint (never the
    # token), so the admission is attributable to the file-backed credential.
    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    # The call site sits between the resource and the fingerprint (#2299).
    assert events =~ "\tread\tcore\tapi\t#{key}\t"
  end

  # Retention (#2255): the agent request record keeps the previous two
  # generations so evidence survives the detection latency of a budget anomaly.
  test "keeps two rotated generations of the agent request record", context do
    events_file = Path.join(context.state_path, "github-quota/agent-requests.tsv")
    # A current file past the 1 MiB rotation cap plus one prior generation; the
    # next call rotates current to `.1` and moves the old `.1` to `.2`.
    File.mkdir_p!(Path.dirname(events_file))
    File.write!(events_file, String.duplicate("x", 1_048_577) <> "\n")
    File.write!("#{events_file}.1", "old-generation-1\n")

    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])

    assert File.read!("#{events_file}.2") == "old-generation-1\n"
    assert File.read!("#{events_file}.1") == String.duplicate("x", 1_048_577) <> "\n"
    assert File.read!(events_file) =~ "\tticket:1670\tread\tgraphql\t"
  end

  test "an ordinary failed call does not create quota holds or probe the API", context do
    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"], FAKE_GH_FAIL: "1")

    refute File.exists?(Path.join(context.state_path, "github-quota/core-hold"))
    refute File.read!(context.calls) =~ "api rate_limit"
  end

  test "a rate-limit failure records exact resource reset holds", context do
    reset = System.os_time(:second) + 3600

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    assert File.read!(Path.join(context.state_path, "github-quota/core-hold")) == "#{reset}\n"
    refute File.exists?(Path.join(context.state_path, "github-quota/graphql-hold"))
  end

  # Production keeps the agent hold dir under the workspace and the shared one
  # under the repo state path; the rest of this suite collapses them onto the
  # same directory, which hid the fact that a hold an agent discovered first
  # never reached anyone else. Reads consult both dirs, so writes publish to both.
  test "a rate-limit failure publishes the hold to both the agent and the shared repo dir", context do
    reset = System.os_time(:second) + 3600
    agent_quota_dir = Path.join(context.workspace, ".aiur-runtime/github-quota")
    shared_quota_dir = Path.join(context.state_path, "github-quota")
    File.mkdir_p!(agent_quota_dir)

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               AIUR_AGENT_QUOTA_STATE_PATH: agent_quota_dir,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    assert agent_quota_dir != shared_quota_dir

    # The discovering agent's own copy...
    assert File.read!(Path.join(agent_quota_dir, "core-hold")) == "#{reset}\n"
    # ...and the copy every other agent and the daemon actually read.
    assert File.read!(Path.join(shared_quota_dir, "core-hold")) == "#{reset}\n"
  end

  # Holds land via temp+rename so a concurrent reader never samples a truncated
  # file and lets a call out during an exhausted window. A leftover temp file
  # would mean the rename never happened.
  test "hold writes leave no temporary files behind", context do
    reset = System.os_time(:second) + 3600
    agent_quota_dir = Path.join(context.workspace, ".aiur-runtime/github-quota")
    File.mkdir_p!(agent_quota_dir)

    assert {_output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               AIUR_AGENT_QUOTA_STATE_PATH: agent_quota_dir,
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: API rate limit exceeded",
               FAKE_RATE_LIMIT: "0 #{reset} 5000 #{reset}"
             )

    for dir <- [agent_quota_dir, Path.join(context.state_path, "github-quota")] do
      refute Enum.any?(File.ls!(dir), &String.contains?(&1, ".tmp."))
    end
  end

  # `gh run watch` is an allowlisted read whose progress arrives on stderr, so
  # the guard passes stderr through as it is written instead of replaying a
  # buffered copy after exit. `tee` ends that pipeline, so this also pins that
  # the real exit status still reaches the caller and that stderr is not
  # emitted twice.
  test "a streamed call surfaces stderr once and preserves the real exit status", context do
    assert {output, 1} =
             run_guard(context, ["pr", "view", "1670"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "boom from gh"
             )

    assert output =~ "boom from gh"
    assert length(String.split(output, "boom from gh")) == 2
  end
end
