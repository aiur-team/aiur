defmodule Aiur.AgentGitHubGuardTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Aiur.AgentGitHubGuard

  setup %{tmp_dir: root} do
    workspace = Path.join(root, "1670")
    state_path = Path.join(root, "state")
    fake_gh = Path.join(root, "real-gh")
    calls = Path.join(root, "calls")
    File.mkdir_p!(workspace)

    File.write!(
      fake_gh,
      """
      #!/bin/sh
      if [ "${1:-} ${2:-}" = "api rate_limit" ]; then
        printf '%s' "${FAKE_RATE_LIMIT:-5000 0 5000 0}"
        exit 0
      fi
      printf '%s %s\n' "${1:-}" "${2:-}" >> "$FAKE_GH_CALLS"
      if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then printf '%s\n' "${FAKE_GH_ERROR:-failed}" >&2; exit 1; fi
      printf 'ok\n'
      """
    )

    File.chmod!(fake_gh, 0o755)
    :ok = AgentGitHubGuard.install(workspace)

    {:ok,
     wrapper: Path.join(AgentGitHubGuard.bin_dir(workspace), "gh"),
     git_wrapper: Path.join(AgentGitHubGuard.bin_dir(workspace), "git"),
     workspace: workspace,
     state_path: state_path,
     fake_gh: fake_gh,
     calls: calls}
  end

  test "records ticket-shaped read and write attribution without command arguments", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "view", "1670"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--body", "secret body"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tticket:1670\tread\tcore\n"
    assert events =~ "\tticket:1670\twrite\tcore\n"
    refute events =~ "secret body"
  end

  # GraphQL is billed in points against its own budget. A row that does not say
  # which budget it spent gets counted against core, putting agent GraphQL
  # traffic in the wrong window (#1805).
  test "names the budget each recorded call was billed to", context do
    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
    assert {"ok\n", 0} = run_guard(context, ["api", "repos/owner/repo/issues"])

    events = File.read!(Path.join(context.state_path, "github-quota/agent-requests.tsv"))
    assert events =~ "\tread\tgraphql\n"
    assert events =~ "\tread\tcore\n"
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

  # The field failure: `gh` refused with a rate-limit error while both primary
  # windows still read healthy. Without a secondary hold the guard recorded
  # nothing and the next call went straight back out.
  test "a rate-limit failure with healthy primary windows records a secondary backoff", context do
    reset = System.os_time(:second) + 3600
    before = System.os_time(:second)

    assert {output, 1} =
             run_guard(context, ["api", "repos/owner/repo/issues"],
               FAKE_GH_FAIL: "1",
               FAKE_GH_ERROR: "HTTP 403: You have exceeded a secondary rate limit",
               FAKE_RATE_LIMIT: "4077 #{reset} 4405 #{reset}"
             )

    assert output =~ "secondary rate limit"

    quota_dir = Path.join(context.state_path, "github-quota")
    refute File.exists?(Path.join(quota_dir, "core-hold"))

    held_until = quota_dir |> Path.join("core-secondary-hold") |> File.read!() |> String.trim() |> String.to_integer()
    assert held_until >= before + 60
    assert held_until <= System.os_time(:second) + 60
  end

  test "a secondary hold prevents an immediate retry of the real gh command", context do
    hold_file = Path.join(context.state_path, "github-quota/core-secondary-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    {_output, 124} = System.cmd(timeout, ["0.2", context.wrapper, "api", "repos/owner/repo/issues/1670"], env: guard_env(context), stderr_to_stdout: true)

    refute File.exists?(context.calls)
  end

  test "a retained hold prevents the real gh command from being retried immediately", context do
    hold_file = Path.join(context.state_path, "github-quota/core-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    timeout = System.find_executable("timeout") || flunk("timeout executable is required for this Linux-only guard test")
    {_output, 124} = System.cmd(timeout, ["0.2", context.wrapper, "api", "repos/owner/repo/issues/1670"], env: guard_env(context), stderr_to_stdout: true)

    refute File.exists?(context.calls)
  end

  test "a core hold does not block an explicitly GraphQL command", context do
    hold_file = Path.join(context.state_path, "github-quota/core-hold")
    File.mkdir_p!(Path.dirname(hold_file))
    File.write!(hold_file, "#{System.os_time(:second) + 60}\n")

    assert {"ok\n", 0} = run_guard(context, ["api", "graphql", "-f", "query=query { viewer { login } }"])
  end

  test "a local gh command bypasses active API holds", context do
    quota_dir = Path.join(context.state_path, "github-quota")
    File.mkdir_p!(quota_dir)
    File.write!(Path.join(quota_dir, "core-hold"), "#{System.os_time(:second) + 60}\n")
    File.write!(Path.join(quota_dir, "graphql-hold"), "#{System.os_time(:second) + 60}\n")

    assert {"ok\n", 0} = run_guard(context, ["version"])
  end

  test "git authentication uses only the agent token for github.com", context do
    global_config = Path.join(context.workspace, ".gitconfig")

    File.write!(
      global_config,
      "[credential]\n\thelper = \"!f() { printf 'username=executor\\npassword=executor-token\\n'; }; f\"\n"
    )

    input = "protocol=https\nhost=github.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               GITHUB_TOKEN: "agent-token",
               GH_TOKEN: "wrong-precedence-token",
               HOME: context.workspace
             )

    assert output =~ "username=x-access-token"
    assert output =~ "password=agent-token"
    refute output =~ "executor-token"

    assert {output, exit_code} =
             run_git_credential(context, input,
               GITHUB_TOKEN: nil,
               GH_TOKEN: nil,
               HOME: context.workspace
             )

    assert exit_code != 0
    refute output =~ "executor-token"
  end

  test "git authentication preserves configured helpers for another host", context do
    global_config = Path.join(context.workspace, ".gitconfig")

    File.write!(
      global_config,
      "[credential]\n\thelper = \"!f() { printf 'username=other\\npassword=other-token\\n'; }; f\"\n"
    )

    input = "protocol=https\nhost=example.com\n\n"

    assert {output, 0} =
             run_git_credential(context, input,
               GITHUB_TOKEN: "agent-token",
               HOME: context.workspace
             )

    assert output =~ "username=other"
    assert output =~ "password=other-token"
    refute output =~ "agent-token"
  end

  test "git push rejects a credential-bearing GitHub remote", context do
    repo = Path.join(context.workspace, "repo")
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd("git", ["init", repo], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", repo, "remote", "add", "origin", "https://agent:embedded-token@github.com/owner/repo.git"],
               stderr_to_stdout: true
             )

    {output, exit_code} =
      System.cmd(context.git_wrapper, ["push", "--dry-run", "origin", "HEAD"],
        cd: repo,
        env: [{"AIUR_REAL_GIT", System.find_executable("git")}, {"GITHUB_TOKEN", "agent-token"}],
        stderr_to_stdout: true
      )

    assert exit_code == 64
    assert output =~ "credential-free https://github.com remote"
    refute output =~ "embedded-token"
  end

  # #1793: 29 tickets were filed mid-run with no `agent:*` label. Each one was
  # undispatchable and absent from every state-scoped view, so the fleet read as
  # having no work left. The skills instruct every filing path to set the
  # disposition in the creation request; this is the part that does not depend
  # on an agent following prose.
  test "an issue create with no dispatch disposition never reaches gh", context do
    assert {output, 78} = run_guard(context, ["issue", "create", "--title", "Something broke"])

    assert output =~ "no dispatch disposition"
    refute File.exists?(context.calls)
  end

  test "a create labelled only with non-lifecycle labels is still refused", context do
    assert {_output, 78} =
             run_guard(context, ["issue", "create", "--title", "x", "--label", "bug,area:dashboard"])

    refute File.exists?(context.calls)
  end

  test "each documented disposition reaches gh, in every flag spelling", context do
    for label <- ~w(agent:todo human:todo needs-triage build-order epic) do
      File.rm_rf!(context.calls)

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", label])

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label=#{label}"])

      assert {"ok\n", 0} = run_guard(context, ["issue", "create", "--title", "x", "-l", label])

      assert {"ok\n", 0} =
               run_guard(context, ["issue", "create", "--title", "x", "--label", "bug,#{label}"])

      assert File.read!(context.calls) == String.duplicate("issue create\n", 4)
    end
  end

  test "the disposition guard does not touch other issue subcommands", context do
    assert {"ok\n", 0} = run_guard(context, ["issue", "comment", "1670", "--body", "hi"])
    assert {"ok\n", 0} = run_guard(context, ["issue", "edit", "1670", "--add-label", "agent:done"])

    assert File.read!(context.calls) =~ "issue comment"
  end

  test "installer rejects symlinked runtime directories", context do
    runtime = Path.join(context.workspace, ".aiur-runtime")
    external = Path.join(Path.dirname(context.workspace), "outside")
    File.rm_rf!(runtime)
    File.mkdir_p!(external)
    File.ln_s!(external, runtime)

    assert {:error, {:unsafe_agent_support_path, ^runtime, :symlink}} =
             AgentGitHubGuard.install(context.workspace)

    refute File.exists?(Path.join(external, "bin/gh"))
  end

  defp run_guard(context, args, extra_env \\ []) do
    System.cmd(context.wrapper, args,
      env: guard_env(context) ++ Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end),
      stderr_to_stdout: true
    )
  end

  defp run_git_credential(context, input, extra_env) do
    env =
      [{"AIUR_REAL_GIT", System.find_executable("git")}] ++
        Enum.map(extra_env, fn {key, value} -> {Atom.to_string(key), value} end)

    System.cmd("sh", ["-c", ~s(printf '%s' "$2" | "$1" credential fill), "sh", context.git_wrapper, input],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp guard_env(context) do
    [
      {"AIUR_REAL_GH", context.fake_gh},
      {"AIUR_REPO_STATE_PATH", context.state_path},
      {"AIUR_AGENT_QUOTA_STATE_PATH", Path.join(context.state_path, "github-quota")},
      {"AIUR_AGENT_WORKSPACE", context.workspace},
      {"FAKE_GH_CALLS", context.calls}
    ]
  end
end
