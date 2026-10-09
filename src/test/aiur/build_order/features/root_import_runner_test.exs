defmodule Aiur.BuildOrder.Features.RootImportRunnerTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.{Features, History}
  alias Aiur.BuildOrder.Features.RootImport
  @at ~U[2026-09-01 10:00:00Z]

  test "disabled runner neither subscribes nor reads" do
    fail = fn -> flunk("disabled runner accessed a store") end
    pid = start_supervised!({RootImport, name: nil, enabled?: false, history: fail, subscribe: fail})
    assert RootImport.status(pid) == :disabled
    send(pid, :run)
    send(pid, {:build_order_history_changed, %{}})
    assert RootImport.status(pid) == :disabled
  end

  test "unavailable or pending History causes no registry reads or writes" do
    for result <- [{:error, %{failure: :history_corrupt}}, {:ok, %{health: %{failure: :backfill_pending}}}] do
      {:ok, pid} = RootImport.start_link(name: nil, history: fn -> result end, subscribe: fn -> :ok end, features: fn _, _ -> flunk("registry accessed") end)
      expected = if elem(result, 0) == :error, do: :history_corrupt, else: :backfill_pending
      assert RootImport.status(pid) == {:unavailable, expected}
      GenServer.stop(pid)
    end
  end

  test "registry and journal failures expose unavailable status and schedule retry" do
    for failure_at <- [:snapshot, :journal] do
      writer = fn
        ^failure_at, _ -> {:error, %{failure: :features_corrupt}}
        :snapshot, _ -> {:ok, %{features: %{"bo-1" => %{}}}}
      end

      {:ok, pid} = RootImport.start_link(name: nil, history: fn -> {:ok, history()} end, subscribe: fn -> :ok end, features: writer)
      assert RootImport.status(pid) == {:unavailable, :features_corrupt}
      assert is_reference(:sys.get_state(pid).timer)
      GenServer.stop(pid)
    end
  end

  test "real stores import on boot, react to history changes and re-plan after restart" do
    {history_pid, features_pid, writer} = stores()
    history_opts = [server: history_pid]
    assert {:ok, _} = History.apply(events(), history_opts)
    assert :ok = History.mark_complete(history_opts)
    opts = [name: nil, history: fn -> History.snapshot(history_opts) end, features: writer]
    pid = start_supervised!({RootImport, opts})
    assert {:ok, %{added: 1, roots: 1, health: %{complete?: true}}} = RootImport.status(pid)
    assert {:ok, before} = Features.journal("bo-1", server: features_pid)
    assert List.last(before).source == "import:build-order"
    assert {:ok, %{feature: "bo-1", joined_at: @at}} = Features.owner(2, server: features_pid)
    send(pid, :run)
    assert {:ok, %{added: 0, roots: 1}} = RootImport.status(pid)
    assert {:ok, ^before} = Features.journal("bo-1", server: features_pid)
    assert {:ok, _} = History.apply([%{number: 1, observed_at: DateTime.add(@at, 1), source: :poll, fields: %{title: "Rename"}}], history_opts)
    # The synchronous History call broadcasts before its reply; cross runner's mailbox barrier.
    :sys.get_state(pid)
    assert is_reference(:sys.get_state(pid).timer)
    send(pid, :run)
    assert {:ok, _} = RootImport.status(pid)
    assert {:ok, s} = Features.snapshot(server: features_pid)
    assert s.features["bo-1"].label == "Rename"
    assert s.features["bo-1"].epics == [%{key: "f-bo-1", label: "Rename"}]
    assert {:ok, renamed} = Features.journal("bo-1", server: features_pid)
    stop_supervised!(RootImport)
    restarted = start_supervised!({RootImport, opts})
    assert {:ok, %{added: 0}} = RootImport.status(restarted)
    assert {:ok, ^renamed} = Features.journal("bo-1", server: features_pid)
  end

  test "stale removal stops subsequent writes and retry re-plans from the real registry" do
    {_, features_pid, real_writer} = stores()
    initial = history()
    {:ok, agent} = Agent.start_link(fn -> %{history: initial, raced?: false} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    writer = fn op, args ->
      if op == :remove and not Agent.get(agent, & &1.raced?) do
        assert {:ok, _} = Features.remove("bo-1", [2], server: features_pid, source: "cli:kev", actor: "kev")
        Agent.update(agent, &%{&1 | raced?: true})
      end

      real_writer.(op, args)
    end

    pid = start_supervised!({RootImport, name: nil, subscribe: fn -> :ok end, history: fn -> {:ok, Agent.get(agent, & &1.history)} end, features: writer})
    assert {:ok, %{added: 1}} = RootImport.status(pid)

    Agent.update(agent, fn state ->
      changed = initial |> put_in([:rows, 2, :parent], :none) |> put_in([:rows, 3], %{number: 3, labels: [], parent: ref(1)})
      %{state | history: changed}
    end)

    send(pid, :run)
    assert RootImport.status(pid) == {:partial, {:not_member, [2]}}
    assert :none = Features.owner(3, server: features_pid)
    assert is_reference(:sys.get_state(pid).timer)
    send(pid, :run)
    assert {:ok, %{removed: 0, added: 1}} = RootImport.status(pid)
    assert {:ok, %{feature: "bo-1"}} = Features.owner(3, server: features_pid)
    assert :none = Features.owner(2, server: features_pid)
  end

  defp stores do
    dir = Aiur.TestSupport.tmp_root!("root-import-runner")
    on_exit(fn -> File.rm_rf!(dir) end)
    name = Module.concat(__MODULE__, "History#{System.unique_integer([:positive])}")
    h = start_supervised!({History, name: name, repository: "aiur-team/aiur", state_dir: Path.join(dir, "history")})
    f = start_supervised!({Features, name: nil, state_dir: Path.join(dir, "features"), general_epics: [], filesystem_sync_fun: fn -> :ok end, alert_fun: fn _, _, _ -> :ok end})
    {h, f, fn op, args -> apply(Features, op, List.update_at(args, -1, &Keyword.put(&1, :server, f))) end}
  end

  defp history do
    %{
      repository: "aiur-team/aiur",
      health: %{complete?: true, failure: nil},
      rows: %{
        1 => %{number: 1, title: "Root", labels: ["build-order"], created_at: @at, closed_at: :none, parent: :none, sub_issues_added: [%{ref: ref(2), at: @at}]},
        2 => %{number: 2, labels: [], parent: ref(1)}
      }
    }
  end

  defp events do
    for {n, row} <- history().rows, do: %{number: n, observed_at: @at, source: :backfill, fields: Map.delete(row, :number)}
  end

  defp ref(n), do: %{owner: "aiur-team", repository: "aiur", number: n}
end
