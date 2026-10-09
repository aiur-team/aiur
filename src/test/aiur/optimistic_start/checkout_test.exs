defmodule Aiur.OptimisticStart.CheckoutTest do
  use ExUnit.Case, async: false

  alias Aiur.{Issue, RepoBase, Workflow}
  alias Aiur.Workspace.{Checkout, Context, Materialize, Provisioner}

  @blocker "aiur/12-work"
  @ticket "aiur/22-dependent"

  setup do
    root = Aiur.TestSupport.tmp_root!("optimistic-checkout")
    source = Path.join(root, "source")
    remote = Path.join(root, "remote.git")
    base = Path.join(root, "base")
    workspace = Path.join(root, "22")
    File.mkdir_p!(source)
    git!(["init", "--bare", "--quiet", "--initial-branch=main", remote])
    git!(["-C", source, "init", "--quiet", "-b", "main"])
    git!(["-C", source, "config", "user.name", "Test"])
    git!(["-C", source, "config", "user.email", "test@example.com"])
    commit!(source, "base")
    git!(["-C", source, "remote", "add", "origin", remote])
    git!(["-C", source, "push", "--quiet", "origin", "main"])
    base_sha = head(source)
    git!(["-C", source, "checkout", "--quiet", "-b", @blocker])
    commit!(source, "blocker")
    sha = head(source)
    git!(["-C", source, "push", "--quiet", "origin", @blocker])
    git!(["clone", "--quiet", remote, base])
    on_exit(fn -> File.rm_rf!(root) end)
    %{source: source, base: base, workspace: workspace, sha: sha, base_sha: base_sha, start_point: %{ref: "refs/heads/" <> @blocker, sha: sha}}
  end

  test "issue context carries only a single optimistic blocker start point", ctx do
    record = %{blockers: [%{identifier: "12", ref: ctx.start_point.ref, sha: ctx.sha}], primary: "12"}
    issue = Map.put(%Issue{id: "22", identifier: "22", title: "Dependent", state: "todo"}, :optimistic_start, record)
    assert Context.build(issue).start_point == ctx.start_point
    assert Context.build(%{issue | optimistic_start: %{record | primary: nil}}).start_point == nil
    assert Context.build(%Issue{id: "22", identifier: "22"}).start_point == nil
  end

  test "prewarm materializes the fresh ticket at the evaluated blocker SHA", ctx do
    assert :ok = Materialize.materialize_from_base(ctx.base, ctx.workspace, @ticket, nil, ctx.start_point)
    assert head(ctx.workspace) == ctx.sha
    assert Checkout.current_branch(ctx.workspace) == @ticket
  end

  test "provisioner threads the start point into prewarm materialization", ctx do
    previous_path = Application.get_env(:aiur, :workflow_file_path)
    config = Path.join(Path.dirname(ctx.base), "config")
    File.write!(config, "tracker:\n  kind: memory\n  base_branch: main\nprewarm:\n  enabled: true\n")
    Workflow.set_workflow_file_path(config)
    previous_state = :sys.get_state(RepoBase)
    :sys.replace_state(RepoBase, &%{&1 | phase: :ready, base_path: ctx.base})

    on_exit(fn ->
      :sys.replace_state(RepoBase, fn _ -> previous_state end)
      if previous_path, do: Workflow.set_workflow_file_path(previous_path), else: Workflow.clear_workflow_file_path()
    end)

    assert {:ok, workspace, :materialized} = Provisioner.ensure_workspace(ctx.workspace, nil, nil, @ticket, nil, ctx.start_point)
    assert workspace == ctx.workspace
    assert head(workspace) == ctx.sha
  end

  test "existing remote ticket branch wins over the optimistic start point", ctx do
    git!(["-C", ctx.source, "checkout", "--quiet", "-b", @ticket])
    commit!(ctx.source, "ticket")
    ticket_sha = head(ctx.source)
    git!(["-C", ctx.source, "push", "--quiet", "origin", @ticket])
    assert :ok = Materialize.materialize_from_base(ctx.base, ctx.workspace, @ticket, nil, ctx.start_point)
    assert head(ctx.workspace) == ticket_sha
  end

  test "missing blocker ref falls back to the live base", ctx do
    point = %{ctx.start_point | ref: "refs/heads/aiur/12-missing"}
    assert :ok = Materialize.materialize_from_base(ctx.base, ctx.workspace, @ticket, nil, point)
    assert head(ctx.workspace) == ctx.base_sha
  end

  test "advanced blocker ref still starts on the evaluated ancestor", ctx do
    commit!(ctx.source, "newer")
    git!(["-C", ctx.source, "push", "--quiet", "origin", @blocker])
    assert :ok = Materialize.materialize_from_base(ctx.base, ctx.workspace, @ticket, nil, ctx.start_point)
    assert head(ctx.workspace) == ctx.sha
  end

  test "rewritten blocker history falls back to base", ctx do
    git!(["-C", ctx.source, "checkout", "--quiet", "-B", @blocker, ctx.base_sha])
    commit!(ctx.source, "rewrite")
    git!(["-C", ctx.source, "push", "--force", "--quiet", "origin", @blocker])
    assert :ok = Materialize.materialize_from_base(ctx.base, ctx.workspace, @ticket, nil, ctx.start_point)
    assert head(ctx.workspace) == ctx.base_sha
  end

  defp commit!(repo, name) do
    File.write!(Path.join(repo, name), name)
    git!(["-C", repo, "add", name])
    git!(["-C", repo, "commit", "--quiet", "-m", name])
  end

  defp head(repo), do: String.trim(git!(["-C", repo, "rev-parse", "HEAD"]))

  defp git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end
end
