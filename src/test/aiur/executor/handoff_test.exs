defmodule Aiur.Executor.HandoffTest do
  use ExUnit.Case, async: false

  alias Aiur.Executor.Handoff
  alias Aiur.Init.Templates
  alias Aiur.RepoBase

  setup do
    tmp = Aiur.TestSupport.tmp_root!("aiur-executor-handoff")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(tmp) end)

    # Keep repo state in the suite root, which lives until after_suite; a
    # late writer must not race deletion of a per-test state root.
    previous_root = Application.get_env(:aiur, :repo_base_root)
    slug = "#{System.pid()}-#{System.unique_integer([:positive])}"
    state_root = Path.join(Application.fetch_env!(:aiur, :test_run_root), "handoff-#{slug}")
    Application.put_env(:aiur, :repo_base_root, state_root)
    on_exit(fn -> restore_repo_root(previous_root) end)

    {:ok, tmp: tmp, repo: "https://github.com/owner/handoff-#{slug}.git"}
  end

  defp restore_repo_root(nil), do: Application.delete_env(:aiur, :repo_base_root)
  defp restore_repo_root(root), do: Application.put_env(:aiur, :repo_base_root, root)

  test "seeds the template after the repository state tree exists", %{tmp: tmp, repo: repo} do
    assert :ok = RepoBase.setup_state(repo, tmp)
    assert :ok = Handoff.ensure(repo, tmp)
    assert File.read!(RepoBase.handoff_path(repo)) == Templates.executor_handoff_template()
  end

  test "imports only the current legacy handoff section and leaves its source intact", %{tmp: tmp, repo: repo} do
    source = Path.join([tmp, "source", "docs", "build-order", "EXECUTOR-HANDOFF.md"])

    File.mkdir_p!(Path.dirname(source))

    File.write!(source, """
    # Build Order Executor Handoff

    ## Current handoff

    Keep this context.

    ---

    ## Superseded checkpoint

    Do not import this context.
    """)

    assert :ok = RepoBase.setup_state(repo, Path.join(tmp, "source"))
    assert :ok = Handoff.ensure(repo, Path.join(tmp, "source"))
    assert File.read!(RepoBase.handoff_path(repo)) == "## Current handoff\n\nKeep this context.\n"
    assert File.read!(source) =~ "## Superseded checkpoint"
  end

  test "tracked index-form handoff seeds the current section before its archive index", %{tmp: tmp, repo: repo} do
    source = Path.expand("../../../..", __DIR__)

    # Guards the tracked document ordering; production seeding already supports this shape.
    assert :ok = RepoBase.setup_state(repo, tmp)
    assert :ok = Handoff.ensure(repo, source)
    seeded = File.read!(RepoBase.handoff_path(repo))
    assert String.starts_with?(seeded, "## New-machine handoff")
    assert seeded =~ "###"
    refute seeded =~ "## Archived checkpoints"
    refute seeded =~ "executor-handoff/"
  end

  test "does not overwrite the current handoff on a later init", %{tmp: tmp, repo: repo} do
    assert :ok = RepoBase.setup_state(repo, tmp)
    File.write!(RepoBase.handoff_path(repo), "current handoff\n")

    assert :ok = Handoff.ensure(repo, tmp)
    assert File.read!(RepoBase.handoff_path(repo)) == "current handoff\n"
  end
end
