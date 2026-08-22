defmodule Aiur.Executor.HandoffTest do
  use ExUnit.Case, async: false

  alias Aiur.Executor.Handoff
  alias Aiur.Init.Templates
  alias Aiur.RepoBase

  setup do
    tmp = Path.join(System.tmp_dir!(), "aiur-executor-handoff-#{System.pid()}-#{System.unique_integer([:positive])}")
    state_root = Path.join(tmp, "state")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    Application.put_env(:aiur, :repo_base_root, state_root)

    on_exit(fn ->
      case previous_root do
        nil -> Application.delete_env(:aiur, :repo_base_root)
        root -> Application.put_env(:aiur, :repo_base_root, root)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "seeds the template after the repository state tree exists", %{tmp: tmp} do
    repo = "https://github.com/owner/repo.git"

    assert :ok = RepoBase.setup_state(repo, tmp)
    assert :ok = Handoff.ensure(repo, tmp)
    assert File.read!(RepoBase.handoff_path(repo)) == Templates.executor_handoff_template()
  end

  test "imports only the current legacy handoff section and leaves its source intact", %{tmp: tmp} do
    repo = "https://github.com/owner/repo.git"
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

  test "does not overwrite the current handoff on a later init", %{tmp: tmp} do
    repo = "https://github.com/owner/repo.git"

    assert :ok = RepoBase.setup_state(repo, tmp)
    File.write!(RepoBase.handoff_path(repo), "current handoff\n")

    assert :ok = Handoff.ensure(repo, tmp)
    assert File.read!(RepoBase.handoff_path(repo)) == "current handoff\n"
  end
end
