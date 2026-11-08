defmodule Aiur.Project.SingletonIsolationTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.OpenIssueSnapshot
  alias Aiur.Orchestrator.OptimisticLedger
  alias Aiur.Orchestrator.SpendCap.Store
  alias Aiur.Project
  alias Aiur.Project.{Context, Table}
  alias Aiur.TestSupport.GroupedScopes, as: GS

  setup do
    root = Path.join(System.tmp_dir!(), "singleton-isolation-#{System.unique_integer([:positive])}")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    on_exit(fn -> Table.drop("o/a") && Table.drop("o/b") end)
    {:ok, a: project("o/a", root), b: project("o/b", root), root: root}
  end

  defp project(repo, root) do
    state_root = Path.join(root, String.replace(repo, "/", "-"))
    File.mkdir_p!(state_root)
    Project.from_machine_entry(%{repo: repo, config: Path.join(state_root, "config")}, state_root)
  end

  defp as(project, fun) do
    Context.put(project)
    fun.()
  after
    Context.delete()
  end

  # Linked to the test process, which carries the project context start_link reads.
  defp start(module, opts), do: {:ok, _pid} = module.start_link(opts)

  defp attrs do
    %{
      attempt_id: "attempt",
      start_trigger: :pr_opened,
      started_at_ms: 100,
      blockers: [%{"id" => "12", "pr_number" => 30, "pr_head_sha_at_start" => "s", "pr_head_ref_at_start" => "refs/heads/aiur/12-s", "pr_state" => "open"}]
    }
  end

  test "open-issue snapshots are per project", %{a: a, b: b} do
    for p <- [a, b], do: as(p, fn -> start(OpenIssueSnapshot, []) end)
    as(a, fn -> OpenIssueSnapshot.put("o", "a", ["7"]) end)

    assert as(a, fn -> :ets.tab2list(Table.ref(OpenIssueSnapshot)) end) != []
    assert as(b, fn -> :ets.tab2list(Table.ref(OpenIssueSnapshot)) end) == []
  end

  test "optimistic ledgers write to their own project's state directory", %{a: a, b: b} do
    for p <- [a, b], do: as(p, fn -> start(OptimisticLedger, []) end)
    assert :ok = as(a, fn -> OptimisticLedger.record_start("10", attrs()) end)

    assert {:ok, [%{"ticket" => "10"}]} = as(a, fn -> OptimisticLedger.open_records() end)
    assert {:ok, []} = as(b, fn -> OptimisticLedger.open_records() end)
    assert File.exists?(Path.join(a.state_root, "optimistic-starts.json"))
    refute File.exists?(Path.join(b.state_root, "optimistic-starts.json"))
  end

  test "spend-cap stores keep separate records and dispatch tables", %{a: a, b: b} do
    identity = GS.identity(5693)

    store_opts = fn p ->
      [
        state_dir: p.state_root,
        repository: p.repo,
        subscribe_fun: fn -> :ok end,
        usage_fun: fn ^identity -> {:ok, %{}} end,
        reserve_event_id_fun: fn -> {:ok, 42} end,
        stop_fun: fn _, _ -> :ok end,
        event_fun: fn _, _, id, _ -> {:ok, id, 1} end,
        transition_fun: fn _, _ -> :ok end
      ]
    end

    for p <- [a, b], do: as(p, fn -> start(Store, store_opts.(p)) end)
    assert {:ok, _} = as(a, fn -> Store.put(identity, "1.25") end)

    assert File.exists?(Path.join(a.state_root, "ticket-spend-caps.json"))
    refute File.exists?(Path.join(b.state_root, "ticket-spend-caps.json"))
    assert {:ok, _} = as(a, fn -> Store.get(identity.identifier) end)
    assert {:error, _} = as(b, fn -> Store.get(identity.identifier) end)
    assert Table.ref(Store) == nil
  end

  test "mixed-case repo names resolve to one project's process and tables", %{root: root} do
    upper = project("O/A", root)
    lower = project("o/a", root)
    as(upper, fn -> start(OpenIssueSnapshot, []) end)

    as(lower, fn -> OpenIssueSnapshot.put("o", "a", ["7"]) end)
    assert as(upper, fn -> :ets.tab2list(Table.ref(OpenIssueSnapshot)) end) != []
    assert as(lower, fn -> GenServer.whereis(Project.via(OpenIssueSnapshot)) end) == as(upper, fn -> GenServer.whereis(Project.via(OpenIssueSnapshot)) end)
  end
end
