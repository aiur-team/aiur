defmodule Aiur.AgentGitHubGuard.GitGuardTest do
  use Aiur.AgentGitHubGuardCase, async: true

  test "git push rejects a credential-bearing GitHub remote", context do
    repo = Path.join(context.workspace, "repo")
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd(real_git(), ["init", repo], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", repo, "remote", "add", "origin", "https://agent:embedded-token@github.com/owner/repo.git"],
               stderr_to_stdout: true
             )

    {output, exit_code} =
      System.cmd(context.git_wrapper, ["push", "--dry-run", "origin", "HEAD"],
        cd: repo,
        env: [{"AIUR_REAL_GIT", real_git()}, {"GITHUB_TOKEN", "agent-token"}],
        stderr_to_stdout: true
      )

    assert exit_code == 64
    assert output =~ "credential-free https://github.com remote"
    refute output =~ "embedded-token"
  end

  test "git push inspects the repository selected by -C", context do
    repo = Path.join(context.workspace, "target-repo")
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd(real_git(), ["-C", repo, "init", "--quiet"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               real_git(),
               ["-C", repo, "remote", "add", "origin", "https://agent:embedded-token@github.com/owner/repo.git"],
               stderr_to_stdout: true
             )

    assert {output, 64} = run_git_guard(context, ["-C", repo, "push", "--dry-run", "origin", "HEAD"])
    assert output =~ "credential-free https://github.com remote"
    refute output =~ "embedded-token"
  end

  test "git wrapper refuses destructive commands without explicit repository context", context do
    init_git_workspace(context)

    for args <- [
          ["reset", "--hard", "HEAD"],
          ["clean", "-fdn"],
          ["checkout", "--", "."],
          ["restore", "--", "."],
          ["restore", "tracked.txt"],
          ["worktree", "remove", "missing-worktree"]
        ] do
      assert {output, 64} = run_git_guard(context, args)
      assert output =~ "destructive git commands require an explicit absolute -C workspace"
    end
  end

  test "git wrapper treats accepted hard-reset abbreviations as destructive", context do
    init_git_workspace(context)
    other = Path.join(Path.dirname(context.workspace), "other-reset-abbreviation")
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", other], stderr_to_stdout: true)

    for option <- ~w(--h --ha --har --hard) do
      assert {output, 64} = run_git_guard(context, ["reset", option, "HEAD"])
      assert output =~ "destructive git commands require an explicit absolute -C workspace"

      assert {output, 64} = run_git_guard(context, ["-C", other, "reset", option, "HEAD"])
      assert output =~ "destructive git target is not the agent workspace"

      assert {_output, 0} =
               run_git_guard(context, ["-C", context.workspace, "reset", option, "HEAD"])
    end
  end

  test "git wrapper rejects deleting clean without a force flag", context do
    init_git_workspace(context)

    config_env = [
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "clean.requireForce",
      GIT_CONFIG_VALUE_0: "false"
    ]

    assert {output, 64} = run_git_guard(context, ["clean", "-d"], config_env)
    assert output =~ "destructive git commands require an explicit absolute -C workspace"

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "clean", "-d", "-e", ".aiur-runtime/"], config_env)

    assert {_output, 0} = run_git_guard(context, ["clean", "--dry-run"], config_env)
  end

  test "git wrapper resolves aliases before classifying destructive commands", context do
    init_git_workspace(context)
    other = Path.join(Path.dirname(context.workspace), "other-alias")
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", other], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "config", "alias.wipe", "reset --hard"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "config", "alias.inspect", "status --short"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(real_git(), ["-C", other, "config", "alias.wipe", "reset --hard"], stderr_to_stdout: true)

    assert {output, 64} = run_git_guard(context, ["wipe"])
    assert output =~ "destructive git commands require an explicit absolute -C workspace"
    assert {_output, 0} = run_git_guard(context, ["-C", context.workspace, "wipe"])
    assert {_output, 0} = run_git_guard(context, ["inspect"])

    assert {output, 64} = run_git_guard(context, ["-C", other, "wipe"])
    assert output =~ "destructive git target is not the agent workspace"

    assert {_, 0} =
             System.cmd(real_git(), ["-C", context.workspace, "config", "alias.shell-wipe", "!git reset --hard"], stderr_to_stdout: true)

    assert {output, 64} = run_git_guard(context, ["-C", context.workspace, "shell-wipe"])
    assert output =~ "shell git aliases cannot be validated safely"

    assert {output, 64} = run_git_guard(context, ["-c", "alias.inline-wipe=reset --hard", "inline-wipe"])
    assert output =~ "inline git aliases cannot bypass repository context"
  end

  test "git wrapper accepts only an explicit context resolving to its workspace", context do
    init_git_workspace(context)
    nested = Path.join(context.workspace, "nested")
    other = Path.join(Path.dirname(context.workspace), "other")
    File.mkdir_p!(nested)
    assert {_, 0} = System.cmd(real_git(), ["init", "--quiet", other], stderr_to_stdout: true)

    assert {_output, 0} = run_git_guard(context, ["-C", context.workspace, "reset", "--hard", "HEAD"])
    assert {_output, 0} = run_git_guard(context, ["-C", nested, "reset", "--hard", "HEAD"])

    for target <- [".", Path.join(context.workspace, "missing"), other] do
      assert {output, 64} = run_git_guard(context, ["-C", target, "reset", "--hard", "HEAD"])
      assert output =~ "destructive git target is not the agent workspace"
      refute output =~ "fatal: cannot change to"
    end
  end

  test "git wrapper derives its workspace from its installed path", context do
    init_git_workspace(context)

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "reset", "--hard", "HEAD"], AIUR_AGENT_WORKSPACE: nil)

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "reset", "--hard", "HEAD"], AIUR_AGENT_WORKSPACE: Path.dirname(context.workspace))
  end

  test "git wrapper rejects competing context selectors for destructive commands", context do
    init_git_workspace(context)
    git_dir = Path.join(context.workspace, ".git")

    for {args, env} <- [
          {["-C", context.workspace, "--git-dir", git_dir, "reset", "--hard", "HEAD"], []},
          {["-C", context.workspace, "--work-tree", context.workspace, "reset", "--hard", "HEAD"], []},
          {["-C", context.workspace, "-c", "core.worktree=#{Path.dirname(context.workspace)}", "reset", "--hard", "HEAD"], []},
          {["-C", context.workspace, "--config-env=core.worktree=FAKE_WORK_TREE", "reset", "--hard", "HEAD"], [FAKE_WORK_TREE: Path.dirname(context.workspace)]},
          {["-C", context.workspace, "reset", "--hard", "HEAD"], [GIT_DIR: git_dir]},
          {["-C", context.workspace, "reset", "--hard", "HEAD"], [GIT_WORK_TREE: context.workspace]}
        ] do
      assert {output, 64} = run_git_guard(context, args, env)
      assert output =~ "destructive git commands cannot use competing repository context"
    end
  end

  test "git wrapper leaves read-only commands available without -C", context do
    init_git_workspace(context)
    assert {_output, 0} = run_git_guard(context, ["status", "--short"])
  end

  # ---------------------------------------------------------------------------
  # `git worktree remove` protection (#2094)
  #
  # #2049 installed the destructive-git guard only into fleet agent
  # workspaces. These cover the extension to every Aiur-spawned process: the
  # same wrapper installed at host level (alongside `aiurdev`) applies two
  # checks to `git worktree remove` regardless of which process invokes it —
  # the worktree must be idle (no live process rooted in it) and must not hold
  # uncommitted work unless the caller deliberately passes the guard's distinct
  # override flag. Losing committed work is recoverable through the reflog;
  # losing uncommitted work is not, and that asymmetry is encoded rather than
  # left to judgement. The #2049 `-C` requirement and its workspace-derived
  # authority survive unchanged for workspace installs.
  # ---------------------------------------------------------------------------

  test "git worktree remove refuses a worktree holding uncommitted changes without the explicit override", context do
    worktree = make_workspace_worktree(context, "wt-dirty")
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    assert {output, 64} =
             run_git_guard(context, ["-C", context.workspace, "worktree", "remove", worktree])

    assert output =~ "has uncommitted changes"
    assert output =~ "--aiur-remove-dirty"
    assert File.dir?(worktree)
  end

  test "the explicit override removes a dirty worktree and supplies git's own force", context do
    worktree = make_workspace_worktree(context, "wt-dirty-override")
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    assert {_output, 0} =
             run_git_guard(context, [
               "-C",
               context.workspace,
               "worktree",
               "remove",
               worktree,
               "--aiur-remove-dirty"
             ])

    refute File.dir?(worktree)
  end

  test "git worktree remove still removes an idle, clean worktree", context do
    # The guard must not refuse the legitimate case: an idle worktree with no
    # uncommitted work is safe to remove, so the protection is a refusal of the
    # dangerous cases, not a blanket ban on `worktree remove`.
    worktree = make_workspace_worktree(context, "wt-clean")

    assert {_output, 0} =
             run_git_guard(context, ["-C", context.workspace, "worktree", "remove", worktree])

    refute File.dir?(worktree)
  end

  test "git's own --force cannot bypass the uncommitted-changes refusal", context do
    # The override is deliberately a distinct flag. git requires `--force` for
    # a dirty removal anyway, so if `--force` also satisfied the guard, a
    # coordinator reflexively passing it would bypass the protection entirely.
    # Only the guard's own `--aiur-remove-dirty` acknowledges the irreversible
    # loss of uncommitted work.
    worktree = make_workspace_worktree(context, "wt-force")
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    assert {output, 64} =
             run_git_guard(context, [
               "-C",
               context.workspace,
               "worktree",
               "remove",
               worktree,
               "--force"
             ])

    assert output =~ "has uncommitted changes"
    assert output =~ "--aiur-remove-dirty"
    assert File.dir?(worktree)
  end

  test "git worktree remove refuses a worktree with a live process rooted in it, naming the pid", context do
    if match?({:unix, :linux}, :os.type()) do
      worktree = make_workspace_worktree(context, "wt-live")

      # The only live process rooted in the worktree is a "sibling wrapper":
      # its command line never mentions git or worktree, so naive
      # `/proc/*/cmdline` matching cannot see it — `/proc/<pid>/cwd` can.
      {port, pid} = spawn_rooted_sibling(worktree, "sleep 60")
      on_exit(fn -> stop_rooted_sibling(port, pid) end)
      :ok = wait_rooted(pid, worktree)

      # The override exists only for uncommitted work; a live worktree is
      # refused with no override at all.
      assert {output, 64} =
               run_git_guard(context, [
                 "-C",
                 context.workspace,
                 "worktree",
                 "remove",
                 worktree,
                 "--aiur-remove-dirty"
               ])

      assert output =~ "pid #{pid} is rooted in"
      assert File.dir?(worktree)
      stop_rooted_sibling(port, pid)
    else
      # The liveness check reads /proc/<pid>/cwd, which is Linux-only; the
      # uncommitted-changes protection above still applies on every platform.
    end
  end

  test "the worktree protection applies to a plain-shell caller outside .aiur-runtime/bin", context do
    host_bin = install_host_wrapper(context)
    {main, worktree} = make_host_worktree(context)
    File.write!(Path.join(worktree, "tracked.txt"), "dirty\n")

    # A plain operator shell resolves the bare `git` through PATH: `~/.aiur/bin`
    # prepended, no AIUR_REAL_GIT, no workspace marker. The host wrapper
    # resolves the real executable from the rest of PATH itself and still
    # refuses the removal.
    assert {output, 64} = run_host_guard(host_bin, main, ["worktree", "remove", worktree])
    assert output =~ "has uncommitted changes"
    assert output =~ "--aiur-remove-dirty"
    assert File.dir?(worktree)
  end

  test "a plain-shell caller cannot remove a live worktree either", context do
    if match?({:unix, :linux}, :os.type()) do
      host_bin = install_host_wrapper(context)
      {main, worktree} = make_host_worktree(context)
      {port, pid} = spawn_rooted_sibling(worktree, "sleep 60")
      on_exit(fn -> stop_rooted_sibling(port, pid) end)
      :ok = wait_rooted(pid, worktree)

      assert {output, 64} = run_host_guard(host_bin, main, ["worktree", "remove", worktree])
      assert output =~ "pid #{pid} is rooted in"
      assert File.dir?(worktree)
      stop_rooted_sibling(port, pid)
    else
      # The liveness check reads /proc/<pid>/cwd, which is Linux-only.
    end
  end

  test "the host wrapper passes every non-worktree command through untouched", context do
    host_bin = install_host_wrapper(context)
    {main, _worktree} = make_host_worktree(context)

    assert {"tracked\n", 0} = run_host_guard(host_bin, main, ["show", "HEAD:tracked.txt"])
    assert {_output, 0} = run_host_guard(host_bin, main, ["status", "--short"])
  end

  # #2362: concurrent review agents on one box picked the same generic worktree
  # path and the second silently repointed the first's checkout at a different
  # branch mid-run, so mutation tests ran against the wrong tree. Creating a
  # worktree at a path that already exists must fail loudly rather than reuse
  # or repoint it. git itself refuses a registered or non-empty path but
  # silently proceeds when the existing path is an empty directory - the gap
  # the guard closes.
  test "git worktree add refuses an existing worktree path instead of repointing it", context do
    worktree = make_workspace_worktree(context, "wt-existing")

    {output, 64} =
      run_git_guard(context, ["-C", context.workspace, "worktree", "add", worktree, "-b", "second"])

    assert output =~ "refusing git worktree add"
    assert output =~ "already exists"
    assert output =~ "pick a fresh unique path"
  end

  test "git worktree add refuses an existing empty directory that git would silently reuse", context do
    init_git_workspace(context)
    empty_dir = Path.join(context.workspace, "wt-empty")
    File.mkdir_p!(empty_dir)

    {output, 64} =
      run_git_guard(context, [
        "-C",
        context.workspace,
        "worktree",
        "add",
        "wt-empty",
        "-b",
        "wt-empty-branch"
      ])

    assert output =~ "refusing git worktree add"
    assert output =~ "already exists"
    # nothing was created inside the existing directory
    refute File.exists?(Path.join(empty_dir, "HEAD"))
  end

  test "git worktree add refuses a registered worktree whose directory was removed", context do
    worktree = make_workspace_worktree(context, "wt-registered")
    File.rm_rf!(worktree)

    {output, 64} =
      run_git_guard(context, ["-C", context.workspace, "worktree", "add", worktree, "-b", "other"])

    assert output =~ "refusing git worktree add"
    assert output =~ "already a registered worktree"
  end

  test "git worktree add -b branch value is not mistaken for the target path", context do
    init_git_workspace(context)
    existing = Path.join(context.workspace, "wt-flag")
    File.mkdir_p!(existing)

    # `-b some-branch` names a branch; the real target path `wt-flag` exists,
    # so the guard must refuse on the path (naming `wt-flag`) rather than
    # reading the branch value as a fresh path and passing through. The names
    # are distinct so a guard that wrongly reads `some-branch` as the target
    # checks a path that does not exist and passes through - the exact
    # regression this test exists to catch.
    {output, 64} =
      run_git_guard(context, [
        "-C",
        context.workspace,
        "worktree",
        "add",
        "-b",
        "some-branch",
        "wt-flag"
      ])

    assert output =~ "refusing git worktree add"
    assert output =~ "wt-flag"
  end

  test "git worktree add -b branch value that matches an existing directory still passes through to the real fresh path", context do
    init_git_workspace(context)
    branch_like_dir = Path.join(context.workspace, "some-branch")
    File.mkdir_p!(branch_like_dir)

    # The branch value `some-branch` happens to match an existing directory,
    # but the real target path `wt-fresh` does not exist. A guard that reads
    # the branch value as the path would refuse on `some-branch`; the correct
    # parse skips the branch value and passes through to create `wt-fresh`.
    {output, 0} =
      run_git_guard(context, [
        "-C",
        context.workspace,
        "worktree",
        "add",
        "-b",
        "some-branch",
        "wt-fresh"
      ])

    refute output =~ "refusing"
    assert File.dir?(Path.join(context.workspace, "wt-fresh"))
  end

  test "git worktree add at a fresh path passes through and creates the worktree", context do
    init_git_workspace(context)

    {output, 0} =
      run_git_guard(context, [
        "-C",
        context.workspace,
        "worktree",
        "add",
        "wt-fresh",
        "-b",
        "wt-fresh-branch"
      ])

    refute output =~ "refusing"
    assert File.dir?(Path.join(context.workspace, "wt-fresh"))
  end
end
