defmodule Aiur.WorkspacePreflightCacheTest do
  use Aiur.TestSupport
  alias Aiur.Events.Exchange

  test "github workspace preflight blocks launch with a path-specific operator alert" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-github-preflight")

    previous_enabled = Application.get_env(:aiur, :workspace_github_preflight_enabled)
    previous_fun = Application.get_env(:aiur, :workspace_github_preflight_fun)
    parent = self()

    try do
      :ok = Exchange.subscribe("system.github.connectivity_lost")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        workspace_root: workspace_root
      )

      Application.put_env(:aiur, :workspace_github_preflight_enabled, true)

      Application.put_env(:aiur, :workspace_github_preflight_fun, fn workspace ->
        send(parent, {:workspace_preflight, workspace})
        {:error, {:github, :dns, %{reason: :nxdomain}}}
      end)

      assert {:error, {:workspace_github_connectivity_failed, workspace, {:github, :dns, %{reason: :nxdomain}}}} =
               Workspace.create_for_issue("MT-GH-PREFLIGHT")

      assert_receive {:workspace_preflight, ^workspace}, 1000

      assert_receive {:event, %{topic: "system.github.connectivity_lost"} = event}, 500
      assert event["message"] =~ "GitHub workspace preflight failed"
      assert event["message"] =~ "workspace=#{workspace}"
      assert event["message"] =~ "GET https://api.github.com/rate_limit"

      assert event["message"] =~
               "GET https://api.github.com/repos/owner/repo/issues?state=open&per_page=1"
    after
      restore_app_env(:workspace_github_preflight_enabled, previous_enabled)
      restore_app_env(:workspace_github_preflight_fun, previous_fun)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      File.rm_rf(workspace_root)
    end
  end

  # #2429 acceptance: a local budget hold during the workspace preflight is a
  # local counter trip, not lost connectivity. Provisioning still fails closed
  # (the hold must clear before the workspace can be used), but the wrong
  # `system.github.connectivity_lost` blocker must not fire.
  test "github workspace preflight local hold fails closed without a connectivity_lost alert" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "aiur-elixir-workspace-github-local-hold-#{System.unique_integer([:positive])}"
      )

    previous_enabled = Application.get_env(:aiur, :workspace_github_preflight_enabled)
    previous_fun = Application.get_env(:aiur, :workspace_github_preflight_fun)
    parent = self()

    try do
      :ok = Exchange.subscribe("system.github.connectivity_lost")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        workspace_root: workspace_root
      )

      Application.put_env(:aiur, :workspace_github_preflight_enabled, true)

      Application.put_env(:aiur, :workspace_github_preflight_fun, fn workspace ->
        send(parent, {:workspace_preflight, workspace})

        {:error, {:github_auth_preflight_failed, %{classification: :local_hold, endpoint: :rate_limit, repo: "owner/repo", token_source: "GITHUB_APP"}}}
      end)

      assert {:error, {:workspace_github_connectivity_failed, workspace, {:github_auth_preflight_failed, %{classification: :local_hold}}}} =
               Workspace.create_for_issue("MT-GH-LOCAL-HOLD")

      assert_receive {:workspace_preflight, ^workspace}, 1000
      refute_receive {:event, %{topic: "system.github.connectivity_lost"}}, 200
    after
      restore_app_env(:workspace_github_preflight_enabled, previous_enabled)
      restore_app_env(:workspace_github_preflight_fun, previous_fun)

      for pattern <- Exchange.bindings_for(self()) do
        Exchange.unsubscribe(pattern)
      end

      File.rm_rf(workspace_root)
    end
  end

  test "github workspace preflight receives remote worker host" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-remote-github-preflight")

    previous_enabled = Application.get_env(:aiur, :workspace_github_preflight_enabled)
    previous_fun = Application.get_env(:aiur, :workspace_github_preflight_fun)
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    parent = self()

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.aiur-remote-workspaces"
      workspace_path = "/remote/home/.aiur-remote-workspaces/owner/repo/MT-GH-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/aiur-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__AIUR_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__AIUR_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"]
      )

      Application.put_env(:aiur, :workspace_github_preflight_enabled, true)

      Application.put_env(:aiur, :workspace_github_preflight_fun, fn workspace, worker_host ->
        send(parent, {:workspace_preflight, workspace, worker_host})
        :ok
      end)

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-GH-REMOTE", "worker-01:2200")
      assert_receive {:workspace_preflight, ^workspace_path, "worker-01:2200"}, 1000

      trace = File.read!(trace_file)

      assert trace =~
               "-o SetEnv=BASH_ENV=/dev/null ENV=/dev/null HOME=/dev/null ZDOTDIR=/dev/null -p 2200 worker-01"

      assert trace =~ "env -u BASH_ENV -u ENV ZDOTDIR=/dev/null HOME=\"$AIUR_REMOTE_HOME\" bash -c"
      assert trace =~ "~/.aiur-remote-workspaces/owner/repo/MT-GH-REMOTE"
    after
      restore_app_env(:workspace_github_preflight_enabled, previous_enabled)
      restore_app_env(:workspace_github_preflight_fun, previous_fun)
      File.rm_rf(test_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-hook-timeout")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace installs agent support (no repo content) when no bootstrap hook is configured" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-workspace-empty")

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join([workspace_root, "project", "MT-608"])
      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)

      # With no bootstrap hook the workspace gets no repo content, but aiur still
      # seeds its bundled agent skills (#689) and GitHub quota guard so a
      # dispatched agent has its operating support without a filesystem search.
      assert {:ok, entries} = File.ls(workspace)
      assert Enum.sort(entries) == [".agents", ".aiur-runtime", ".claude", ".codex", ".fake"]
      assert File.exists?(Path.join([workspace, ".agents", "skills", "aiur-agent", "SKILL.md"]))
      assert File.exists?(Path.join([workspace, ".claude", "skills", "aiur-agent", "SKILL.md"]))
      assert File.exists?(Path.join([workspace, ".aiur-runtime", "bin", "gh"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  # Regression for #2287: the workflow file path used to live only in the
  # VM-global app env, so a concurrent async test's `setup` could clobber it
  # between this test's `write_workflow_file!/2` and its read. `Workspace`
  # resolution then read a sibling's config — the observed failure resolved
  # `MT-608` under the default `/tmp/aiur_workspaces` instead of this test's own
  # `workspace_root`. The path is now pinned per process, so a clobber of the
  # global env must not move this test's reads.
  test "workspace resolution ignores a concurrent clobber of the global workflow path" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-workspace-clobber")

    other_root = Aiur.TestSupport.tmp_root!("aiur-workspace-clobber-other")

    try do
      path = Workflow.workflow_file_path()
      other = Path.join(Path.dirname(path), "clobber-other-config.yaml")

      write_workflow_file!(path, workspace_root: workspace_root)
      write_workflow_file!(other, workspace_root: other_root)

      # A concurrent async sibling's setup lands here: it re-points the
      # VM-global path at its own config and reloads the shared WorkflowStore
      # onto it — exactly the race the issue reports. The raw app-env write
      # leaves this process's per-test pin untouched.
      Application.put_env(:aiur, :workflow_file_path, other)
      :ok = WorkflowStore.force_reload()

      # This test's own reads must stay pinned to its own path and root.
      assert Workflow.workflow_file_path() == path

      workspace = Path.join([workspace_root, "project", "MT-608"])
      assert {:ok, canonical_workspace} = Aiur.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      refute File.exists?(Path.join([other_root, "project", "MT-608"]))
    after
      File.rm_rf(workspace_root)
      File.rm_rf(other_root)
    end
  end

  test "workspace before_run seeds warm cache from configured bootstrap image" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-bootstrap-image")

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("AIUR_TEST_DOCKER_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_TEST_DOCKER_TRACE", previous_trace)
    end)

    try do
      fake_bin = Path.join(test_root, "bin")
      workspace_root = Path.join(test_root, "workspaces")
      trace_file = Path.join(test_root, "docker.trace")

      File.mkdir_p!(fake_bin)
      write_fake_docker!(Path.join(fake_bin, "docker"))

      System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
      System.put_env("AIUR_TEST_DOCKER_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_bootstrap_image: "ghcr.io/its-everdred/aiur:latest",
        workspace_bootstrap_image_pull: true,
        hook_before_run: "echo before > before-run.log"
      )

      assert Config.settings!().workspace.bootstrap_image == "ghcr.io/its-everdred/aiur:latest"
      assert Config.workspace_bootstrap_image() == "ghcr.io/its-everdred/aiur:latest"
      assert Config.workspace_bootstrap_image_pull?()

      assert {:ok, workspace} = Workspace.create_for_issue("MT-IMAGE")
      assert :ok = Workspace.run_before_run_hook(workspace, "MT-IMAGE")

      assert File.read!(Path.join(workspace, "before-run.log")) == "before\n"
      assert File.read!(Path.join([workspace, "src", "deps", "from-image.txt"])) == "warm deps\n"
      assert File.read!(Path.join([workspace, "src", "_build", "from-image.txt"])) == "warm build\n"

      trace = File.read!(trace_file)
      assert trace =~ "ARGV:pull ghcr.io/its-everdred/aiur:latest"
      assert trace =~ "ARGV:run --rm --user"
      assert trace =~ "--volume #{workspace}:/workspace"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace bootstrap image keeps existing warm cache directories" do
    test_root = Aiur.TestSupport.tmp_root!("aiur-elixir-workspace-bootstrap-image-existing")

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("AIUR_TEST_DOCKER_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("AIUR_TEST_DOCKER_TRACE", previous_trace)
    end)

    try do
      fake_bin = Path.join(test_root, "bin")
      workspace_root = Path.join(test_root, "workspaces")
      trace_file = Path.join(test_root, "docker.trace")

      File.mkdir_p!(fake_bin)
      write_fake_docker!(Path.join(fake_bin, "docker"))

      System.put_env("PATH", fake_bin <> ":" <> (previous_path || ""))
      System.put_env("AIUR_TEST_DOCKER_TRACE", trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_bootstrap_image: "ghcr.io/its-everdred/aiur:latest"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-IMAGE-EXISTING")
      File.mkdir_p!(Path.join([workspace, "src", "deps"]))
      File.mkdir_p!(Path.join([workspace, "src", "_build"]))
      File.write!(Path.join([workspace, "src", "deps", "keep.txt"]), "existing deps\n")
      File.write!(Path.join([workspace, "src", "_build", "keep.txt"]), "existing build\n")

      assert :ok = Workspace.run_before_run_hook(workspace, "MT-IMAGE-EXISTING")

      assert File.read!(Path.join([workspace, "src", "deps", "keep.txt"])) == "existing deps\n"
      assert File.read!(Path.join([workspace, "src", "_build", "keep.txt"])) == "existing build\n"
      refute File.exists?(Path.join([workspace, "src", "deps", "from-image.txt"]))
      refute File.exists?(Path.join([workspace, "src", "_build", "from-image.txt"]))

      trace = File.read!(trace_file)
      refute trace =~ "ARGV:pull "
      assert trace =~ "ARGV:run --rm"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root = Aiur.TestSupport.tmp_root!("aiur-elixir-issue-workspace-cleanup")

    try do
      target_workspace = Path.join([workspace_root, "project", "S_1"])

      untouched_workspace =
        Path.join([workspace_root, "project", "OTHER-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root = Aiur.TestSupport.tmp_root!("aiur-elixir-missing-workspaces")

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  defp write_fake_docker!(path) do
    File.write!(path, """
    #!/bin/sh
    trace_file="${AIUR_TEST_DOCKER_TRACE:-/tmp/aiur-fake-docker.trace}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    if [ "$1" = "pull" ]; then
      exit 0
    fi

    if [ "$1" != "run" ]; then
      exit 9
    fi

    workspace=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --volume)
          shift
          mount="$1"
          workspace="${mount%:/workspace}"
          ;;
      esac
      shift || true
    done

    if [ -n "$workspace" ]; then
      if [ ! -e "$workspace/src/deps" ]; then
        mkdir -p "$workspace/src/deps"
        printf 'warm deps\\n' > "$workspace/src/deps/from-image.txt"
      fi

      if [ ! -e "$workspace/src/_build" ]; then
        mkdir -p "$workspace/src/_build"
        printf 'warm build\\n' > "$workspace/src/_build/from-image.txt"
      fi
    fi

    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_app_env(key, value), do: Application.put_env(:aiur, key, value)
end
