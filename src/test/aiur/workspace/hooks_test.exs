defmodule Aiur.Workspace.HooksTest do
  use Aiur.TestSupport

  alias Aiur.GitHub.AuthPreflight
  alias Aiur.Workflow
  alias Aiur.Workspace.Hooks

  setup do
    test_root = Aiur.TestSupport.tmp_root!("hooks_test")
    workspace = Path.join(test_root, "ws")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(test_root) end)
    {:ok, workspace: workspace, test_root: test_root}
  end

  test "run_after_create/4 keeps build gate support outside the empty reconstruction stage", %{workspace: workspace, test_root: test_root} do
    sentinel = Path.join(workspace, "hook-ran")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: """
      test -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)"
      touch hook-ran
      """
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_create(workspace, issue_context, true, nil)
    assert File.exists?(sentinel)
    refute File.exists?(Path.join(workspace, ".aiur-runtime"))
  end

  test "run_after_create/4 stages logs-only reconstruction and preserves the prior event stream", %{
    workspace: workspace,
    test_root: test_root
  } do
    log_path = Path.join([workspace, "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "{\"event\":\"alert\"}\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: "printf rebuilt > README.md"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_create(workspace, issue_context, true, nil)

    assert File.read!(Path.join(workspace, "README.md")) == "rebuilt"
    assert File.read!(log_path) == "{\"event\":\"alert\"}\n"
  end

  test "run_after_create/4 cleans sibling support after a failed reconstruction", %{
    workspace: workspace,
    test_root: test_root
  } do
    log_path = Path.join([workspace, "logs", "agent.ndjson"])
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, "{\"event\":\"alert\"}\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: "exit 42"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    assert {:error, {:workspace_hook_failed, "after_create", 42, ""}} =
             Hooks.run_after_create(workspace, issue_context, true, nil)

    assert File.read!(log_path) == "{\"event\":\"alert\"}\n"
    assert File.ls!(test_root) == ["ws"]
  end

  test "run_after_create/4 with created? :materialized returns :ok and hook does NOT run", %{workspace: workspace, test_root: test_root} do
    sentinel = Path.join(workspace, "hook-ran-materialized")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_create: "touch #{sentinel}"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_create(workspace, issue_context, :materialized, nil)
    refute File.exists?(sentinel)
  end

  test "run_after_run/3 with a failing after_run hook returns :ok (failure ignored)", %{workspace: workspace, test_root: test_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      hook_after_run: "exit 1"
    )

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_after_run(workspace, issue_context, nil)
  end

  test "run_github_preflight/3 with preflight disabled returns :ok", %{workspace: workspace} do
    prev = Application.get_env(:aiur, :workspace_github_preflight_enabled)
    Application.put_env(:aiur, :workspace_github_preflight_enabled, false)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:aiur, :workspace_github_preflight_enabled)
        v -> Application.put_env(:aiur, :workspace_github_preflight_enabled, v)
      end
    end)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    assert :ok = Hooks.run_github_preflight(workspace, issue_context, nil)
  end

  # #2444 acceptance 1 at the run boundary: a correctly-classified, short,
  # self-clearing local budget hold during the workspace preflight is waited
  # out by `AuthPreflight` (first attempt held, `reset_at` a couple of seconds
  # out), so `run_github_preflight` returns `:ok` instead of the
  # `{:workspace_github_connectivity_failed, ...}` that would terminate the
  # agent run. The sleep is injected so the test asserts on the run surviving
  # (a `:ok`, not a failure tuple), not merely on a log line or a real 2s wait.
  test "run_github_preflight waits out a short local hold so the run is not terminated", %{workspace: workspace} do
    token_cache_key = {Aiur.GitHub.Config, :resolved_token}
    prev_token = System.get_env("GITHUB_TOKEN")
    prev_cached_token = :persistent_term.get(token_cache_key, :unset)
    prev_enabled = Application.get_env(:aiur, :workspace_github_preflight_enabled)
    prev_fun = Application.get_env(:aiur, :workspace_github_preflight_fun)
    parent = self()

    :persistent_term.erase(token_cache_key)
    System.put_env("GITHUB_TOKEN", "preflight-token")

    on_exit(fn ->
      case prev_enabled do
        nil -> Application.delete_env(:aiur, :workspace_github_preflight_enabled)
        v -> Application.put_env(:aiur, :workspace_github_preflight_enabled, v)
      end

      case prev_fun do
        nil -> Application.delete_env(:aiur, :workspace_github_preflight_fun)
        v -> Application.put_env(:aiur, :workspace_github_preflight_fun, v)
      end

      restore_env("GITHUB_TOKEN", prev_token)

      case prev_cached_token do
        :unset -> :persistent_term.erase(token_cache_key)
        token -> :persistent_term.put(token_cache_key, token)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo"
    )

    Application.put_env(:aiur, :workspace_github_preflight_enabled, true)

    Application.put_env(:aiur, :workspace_github_preflight_fun, fn _workspace, _worker_host ->
      send(parent, :workspace_preflight)

      {:ok, counter} = Agent.start_link(fn -> 0 end)
      reset_at = DateTime.add(DateTime.utc_now(), 2, :second)
      hold = %{reason: :shared_budget, resource: "core", reset_at: reset_at}

      AuthPreflight.preflight_auth(
        request_fun: fn _request ->
          attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

          if attempt == 1 do
            {:error, {:aiur, :locally_held, hold}}
          else
            {:ok, %{status: 200, headers: [{"x-ratelimit-remaining", "42"}], body: %{}}}
          end
        end,
        gh_auth_status_fun: fn -> {:ok, :not_installed} end,
        local_hold_sleep_fun: fn _ms -> :ok end
      )
    end)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    assert :ok = Hooks.run_github_preflight(workspace, issue_context, nil)
    assert_receive :workspace_preflight
  end

  test "run_hook/5 local applies env scrub to release launcher variables", %{workspace: workspace} do
    release_root = Path.join(workspace, "release")
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    release_bin = Path.join(release_root, "bin")
    user_bin = Path.join(workspace, "toolchain/bin")

    release_env = [
      {"RELEASE_NODE", "hooks-test"},
      {"AIUR_RELEASE_DIR", release_root},
      {"ROOTDIR", release_root},
      {"BINDIR", release_erts_bin},
      {"EMU", "beam"},
      {"PROGNAME", "erl"},
      {"PATH", Enum.join([release_erts_bin, release_bin, user_bin, System.fetch_env!("PATH")], ":")}
    ]

    previous_env =
      Map.new(release_env, fn {name, _value} ->
        {name, System.get_env(name)}
      end)

    Enum.each(release_env, fn {name, value} -> System.put_env(name, value) end)

    on_exit(fn ->
      Enum.each(previous_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    command =
      ~s'test -z "$RELEASE_NODE" -a -z "$ROOTDIR" -a -z "$BINDIR" -a -z "$EMU" -a -z "$PROGNAME" && case ":$PATH:" in *:"#{release_erts_bin}":*|*:"#{release_bin}":*) exit 31 ;; esac && case ":$PATH:" in *:"#{user_bin}":*) ;; *) exit 32 ;; esac'

    assert :ok = Hooks.run_hook(command, workspace, issue_context, "before_run", nil)
  end

  test "run_hook/5 passes the generated ticket branch to local hooks", %{workspace: workspace} do
    issue_context = %{
      issue_id: 1,
      issue_identifier: "123",
      issue_state: nil,
      issue_labels: [],
      pr_head_ref: nil,
      branch_name: "aiur/123-add-new-test-cases"
    }

    assert :ok =
             Hooks.run_hook(
               ~s(test "$AIUR_TICKET_BRANCH" = "aiur/123-add-new-test-cases"),
               workspace,
               issue_context,
               "after_create",
               nil
             )
  end

  test "remote hook command exports the generated ticket branch", %{workspace: workspace} do
    issue_context = %{
      issue_id: 1,
      issue_identifier: "123",
      issue_state: nil,
      issue_labels: [],
      pr_head_ref: nil,
      branch_name: "aiur/123-add-new-test-cases"
    }

    command = Hooks.remote_hook_command("git checkout \"$AIUR_TICKET_BRANCH\"", workspace, issue_context)

    assert command =~ "export AIUR_TICKET_BRANCH='aiur/123-add-new-test-cases';"
    assert command =~ "cd '#{workspace}' && unset "
    assert command =~ "git checkout \"$AIUR_TICKET_BRANCH\""
  end

  test "remote hook command scrubs only launcher values owned by the remote Aiur release", %{workspace: workspace} do
    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    release_root = Path.join(workspace, "release")
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    user_bin = Path.join(workspace, "toolchain/bin")

    command =
      Hooks.remote_hook_command(
        ~s'test -z "$ROOTDIR" -a -z "$BINDIR" -a -z "$EMU" -a -z "$PROGNAME" && case ":$PATH:" in *:"#{release_erts_bin}":*) exit 31 ;; esac && case ":$PATH:" in *:"#{user_bin}":*) ;; *) exit 32 ;; esac',
        workspace,
        issue_context
      )

    assert {_, 0} =
             System.cmd("bash", ["-lc", command],
               stderr_to_stdout: true,
               env: [
                 {"AIUR_RELEASE_DIR", release_root},
                 {"ROOTDIR", release_root},
                 {"BINDIR", release_erts_bin},
                 {"EMU", "beam"},
                 {"PROGNAME", "erl"},
                 {"PATH", Enum.join([release_erts_bin, user_bin, System.fetch_env!("PATH")], ":")}
               ]
             )
  end

  test "remote hook command preserves unrelated user launcher variables and PATH", %{workspace: workspace} do
    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    command =
      Hooks.remote_hook_command(
        ~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"),
        workspace,
        issue_context
      )

    unrelated_path = "/opt/user-otp/bin:/usr/local/bin:/usr/bin"

    assert {output, 0} =
             System.cmd("bash", ["-lc", command],
               stderr_to_stdout: true,
               env: [
                 {"AIUR_RELEASE_DIR", "/opt/aiur/release"},
                 {"ROOTDIR", "/opt/user-otp"},
                 {"BINDIR", "/opt/user-otp/bin"},
                 {"EMU", "custom-beam"},
                 {"PROGNAME", "custom-erl"},
                 {"PATH", unrelated_path}
               ]
             )

    assert ["/opt/user-otp", "/opt/user-otp/bin", "custom-beam", "custom-erl", path] =
             String.split(output, "\n")

    assert String.starts_with?(path, unrelated_path)
  end

  test "remote hook command preserves unrelated values beside release-owned values", %{workspace: workspace} do
    issue_context = %{issue_id: 1, issue_identifier: "test", issue_state: nil, issue_labels: [], pr_head_ref: nil}
    release_root = Path.join(workspace, "release")
    release_erts_bin = Path.join([release_root, "erts-16.4", "bin"])
    user_bin = Path.join(workspace, "toolchain/bin")

    command =
      Hooks.remote_hook_command(
        ~s(printf '%s\n%s\n%s\n%s\n%s' "$ROOTDIR" "$BINDIR" "$EMU" "$PROGNAME" "$PATH"),
        workspace,
        issue_context
      )

    assert {output, 0} =
             System.cmd("bash", ["-lc", command],
               stderr_to_stdout: true,
               env: [
                 {"AIUR_RELEASE_DIR", release_root},
                 {"ROOTDIR", release_root},
                 {"BINDIR", user_bin},
                 {"EMU", "custom-beam"},
                 {"PROGNAME", "custom-erl"},
                 {"PATH", Enum.join([release_erts_bin, user_bin, System.fetch_env!("PATH")], ":")}
               ]
             )

    assert ["", ^user_bin, "custom-beam", "custom-erl", path] = String.split(output, "\n")
    refute path =~ release_erts_bin
    assert path =~ user_bin
  end

  test "remote hook command expands repository state under the worker home", %{workspace: workspace, test_root: test_root} do
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, Path.join(test_root, "daemon-state"))

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        root -> Application.put_env(:aiur, :repo_base_root, root)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      tracker_kind: "github",
      tracker_repo: "owner/project"
    )

    command = Hooks.remote_hook_command("true", workspace, %{issue_id: 1, issue_identifier: "123"})

    assert command =~ "AIUR_REPO_STATE_PATH='~/.aiur/repo/owner/project'"
    assert command =~ "AIUR_REPO_STATE_PATH=\"$HOME/${AIUR_REPO_STATE_PATH#\\~/}\""
    refute command =~ Path.join([test_root, "daemon-state", "owner", "project"])
  end

  test "remote hook command exports a neutral state path for non-GitHub trackers", %{workspace: workspace, test_root: test_root} do
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, Path.join(test_root, "daemon-state"))

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        root -> Application.put_env(:aiur, :repo_base_root, root)
      end
    end)

    # Default test config is a Linear tracker with no repo slug.
    command = Hooks.remote_hook_command("true", workspace, %{issue_id: 1, issue_identifier: "123"})

    assert command =~ "AIUR_REPO_STATE_PATH='~/.aiur/repo/unknown/unknown'"
    assert command =~ "AIUR_REPO_STATE_PATH=\"$HOME/${AIUR_REPO_STATE_PATH#\\~/}\""
  end

  test "local hooks receive a usable state path for non-GitHub trackers (no ${VAR:?} abort)", %{
    workspace: workspace,
    test_root: test_root
  } do
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, Path.join(test_root, "daemon-state"))

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        root -> Application.put_env(:aiur, :repo_base_root, root)
      end
    end)

    issue_context = %{issue_id: 1, issue_identifier: "123", issue_state: nil, issue_labels: [], pr_head_ref: nil}

    # Mirrors the scaffolded `.aiur/examples/hooks.example` guard: when the
    # state path is unset, `${VAR:?}` aborts the whole script before mkdir.
    command =
      ~s(cache_root="${AIUR_REPO_STATE_PATH:?Aiur must provide a repository state path}"; ) <>
        ~s(mkdir -p "$cache_root/.aiur-hex" "$cache_root/.aiur-mix" "$cache_root/.aiur-npm-cache" "$cache_root/meta/retros"; ) <>
        ~s(touch "$cache_root/meta/findings.ndjson"; ) <>
        ~s(test -f "$cache_root/meta/findings.ndjson")

    assert :ok = Hooks.run_hook(command, workspace, issue_context, "before_run", nil)
  end
end
