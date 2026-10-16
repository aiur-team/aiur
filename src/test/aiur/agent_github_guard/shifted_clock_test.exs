defmodule Aiur.AgentGitHubGuard.ShiftedClockTest do
  # #4714: a worker under libfaketime (+30 d) kept the live quota paths. Its
  # guarded calls wrote holds a month ahead and deleted real holds as expired.
  use Aiur.AgentGitHubGuardCase, async: true

  @thirty_days 30 * 86_400
  @secondary_failure [
    FAKE_GH_FAIL: "1",
    FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit"
  ]

  # A `date` that answers `+%s` thirty days fast, the way libfaketime does,
  # without needing libfaketime installed. Linux-only: the guard compares it to `/proc`.
  defp fast_clock(context) do
    bin = Path.join(context.tmp_dir, "fast-clock")
    File.mkdir_p!(bin)
    real = System.find_executable("date") || flunk("date executable is required for this guard test")
    script = Path.join(bin, "date")

    File.write!(script, """
    #!/bin/sh
    case "$*" in
      *+%s*) printf '%s\\n' $(( $(#{real} -u +%s) + #{@thirty_days} )) ;;
      *) exec #{real} "$@" ;;
    esac
    """)

    File.chmod!(script, 0o755)
    [PATH: bin <> ":" <> System.get_env("PATH", "")]
  end

  defp tree_digest(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, root), if(File.regular?(path), do: File.read!(path), else: :dir)} end)
  end

  defp canary_quota_dir(context) do
    quota_dir = Path.join(context.state_path, "github-quota")
    File.mkdir_p!(quota_dir)
    File.write!(Path.join(quota_dir, "agent-requests.tsv"), "canary\n")
    quota_dir
  end

  test "a fast-clock guard call does not touch the shared quota dir", context do
    quota_dir = canary_quota_dir(context)
    before = tree_digest(quota_dir)
    reset = System.os_time(:second) + 120

    # An exhausted primary window: a trusted clock would publish core-hold here.
    assert {output, 1} = run_guard(context, ["api", "repos/owner/repo/issues"], fast_clock(context) ++ @secondary_failure ++ [FAKE_RATE_LIMIT: "0 #{reset} 4405 #{reset}"])

    assert output =~ "off the kernel clock; ignoring shared GitHub quota state"
    assert tree_digest(quota_dir) == before
  end

  test "FAKETIME alone marks the clock untrusted", context do
    quota_dir = canary_quota_dir(context)
    before = tree_digest(quota_dir)
    reset = System.os_time(:second) + 120

    assert {output, 1} = run_guard(context, ["api", "repos/owner/repo/issues"], [FAKETIME: "+30d"] ++ @secondary_failure ++ [FAKE_RATE_LIMIT: "0 #{reset} 4405 #{reset}"])

    assert output =~ "FAKETIME is set"
    assert tree_digest(quota_dir) == before
  end

  test "a fast-clock reader does not delete a real hold", context do
    hold_file = Path.join(canary_quota_dir(context), "graphql-secondary-hold")
    hold = "#{System.os_time(:second) + 120}\n"
    File.write!(hold_file, hold)

    assert {output, 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"], fast_clock(context))

    assert output =~ "ok"
    assert File.read(hold_file) == {:ok, hold}
  end

  test "control: a trusted clock still publishes shared holds", context do
    quota_dir = canary_quota_dir(context)
    reset = System.os_time(:second) + 120

    assert {output, 1} = run_guard(context, ["api", "repos/owner/repo/issues"], @secondary_failure ++ [FAKE_RATE_LIMIT: "0 #{reset} 4405 #{reset}"])

    refute output =~ "ignoring shared GitHub quota state"
    assert File.read!(Path.join(quota_dir, "core-hold")) == "#{reset}\n"
  end
end
