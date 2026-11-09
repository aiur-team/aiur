defmodule Aiur.DaemonIdleWorkTest do
  use Aiur.TestSupport

  alias Aiur.{AgentQueueStore, AlertFeed, AlertLedger, Issue, PathSafety}
  alias Aiur.Config.SettingsSnapshot
  alias Aiur.Orchestrator.{State, StatusReport, ToolchainPreflight, TrackerHealth}

  @moduletag :tmp_dir
  @file_call {:file, :call, 2}
  @canonicalize {PathSafety, :canonicalize, 1}
  @projection {Aiur.AlertFeed.Projection, :resolve, 1}
  @identifiers {StatusReport, :snapshot_identifiers, 1}
  @queue_read {AgentQueueStore, :list_pending, 2}

  test "path and symlink segment walks never call file_server", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "real"))
    File.ln_s!("real", Path.join(dir, "link"))
    candidate = Path.join(dir, "link/missing/child")
    expected = Path.join(dir, "real/missing/child")

    {result, calls} = calls([@file_call], fn -> PathSafety.contained?(dir, candidate) end)
    assert {:ok, %{root: ^dir, candidate: ^expected}} = result
    assert calls == []
  end

  test "settings batches reuse a root across nested checks and discard it on failure", %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    first = Path.join(dir, "first")
    second = Path.join(dir, "second")
    File.mkdir_p!(first)
    File.mkdir_p!(second)
    File.ln_s!(first, root)

    {_result, calls} =
      calls([@canonicalize, @file_call], fn ->
        assert_raise RuntimeError, "batch failed", fn ->
          SettingsSnapshot.run(fn ->
            for _ <- 1..4 do
              SettingsSnapshot.run(fn ->
                assert {:ok, %{root: ^first}} = PathSafety.contained?(root, Path.join(root, "child"))
              end)
            end

            raise "batch failed"
          end)
        end
      end)

    assert Enum.count(calls, &(&1 == {PathSafety, :canonicalize, [root]})) == 1
    refute Enum.any?(calls, &match?({:file, :call, _}, &1))
    File.rm!(root)
    File.ln_s!(second, root)
    assert {:ok, %{root: ^second}} = SettingsSnapshot.run(fn -> PathSafety.contained?(root, Path.join(root, "child")) end)
  end

  test "cached roots do not cache candidates or absent roots", %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    candidate = Path.join(root, "candidate")
    absent = Path.join(dir, "absent")

    SettingsSnapshot.run(fn ->
      assert {:ok, %{candidate: ^candidate}} = PathSafety.contained?(root, candidate)
      File.ln_s!(outside, candidate)
      assert {:error, :outside_root} = PathSafety.contained?(root, candidate)
      assert {:ok, ^absent} = PathSafety.canonical_root(absent)
      File.ln_s!(outside, absent)
      assert {:ok, ^outside} = PathSafety.canonical_root(absent)
    end)
  end

  test "tracker preflight never folds the alert projection, including firing and clearing" do
    previous = Application.fetch_env!(:aiur, :toolchain_preflight_opts)
    on_exit(fn -> Application.put_env(:aiur, :toolchain_preflight_opts, previous) end)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    missing = ~s([{"version":"28.5","requested_version":"28.5","install_path":"/missing","installed":false}])
    opts = [mise: "/mise", runner: fn _, _, _ -> {missing, 0} end]
    Application.put_env(:aiur, :toolchain_preflight_opts, opts)

    {_result, calls} =
      calls([@projection], fn ->
        for _ <- 1..3 do
          assert {:error, {:toolchain_missing, _}, %State{}} = TrackerHealth.ensure_tracker_preflight(%State{})
        end

        assert AlertFeed.condition_state(ToolchainPreflight.alert_name()) == :firing
        Application.put_env(:aiur, :toolchain_preflight_opts, mise: nil)
        assert {:ok, %State{}} = TrackerHealth.ensure_tracker_preflight(%State{})
        assert AlertFeed.condition_state(ToolchainPreflight.alert_name()) == :resolved
      end)

    assert calls == []
  end

  test "snapshot scans identifiers once and preserves only visible queue items" do
    {store, visible} = enqueue(AgentQueueStore.new(), "CPU-1")
    {store, _hidden} = enqueue(store, "hidden")
    state = %State{last_polled_issues: %{"1" => %Issue{id: "1", identifier: "CPU-1"}}, queue_store: store}

    {input, calls} = calls([@identifiers], fn -> StatusReport.snapshot_input(state) end)
    assert Enum.count(calls, &match?({StatusReport, :snapshot_identifiers, [_]}, &1)) == 1
    assert AgentQueueStore.list_pending(input.queue_store, "CPU-1") == [visible]
    assert AgentQueueStore.list_pending(input.queue_store, "hidden") == []
  end

  test "an empty queue snapshot never scans per-ticket queue indexes" do
    state = %State{last_polled_issues: Map.new(1..530, &{"#{&1}", %Issue{id: "#{&1}", identifier: "CPU-#{&1}"}})}
    {input, calls} = calls([@queue_read], fn -> StatusReport.snapshot_input(state) end)
    assert input.queue_store == AgentQueueStore.new()
    assert calls == []
  end

  test "targeted condition reads ignore unrelated topics and preserve literal resolution topics", %{tmp_dir: dir} do
    path = Path.join(dir, "alerts.ndjson")
    now = DateTime.utc_now()

    for {topic, offset} <- [{"system.target", -3}, {"system.target.resolved", -2}, {"system.other", -1}] do
      assert :ok = AlertLedger.append(%{"event" => "alert", "topic" => topic, "timestamp" => DateTime.to_iso8601(DateTime.add(now, offset))}, ledger_path: path)
    end

    opts = [ledger_paths: [path]]
    {states, calls} = calls([{AlertFeed, :condition_topic, 1}], fn -> AlertFeed.condition_states(["system.target", "system.absent"], opts) end)
    assert states == %{"system.target" => :resolved, "system.absent" => :unknown}
    assert calls == []
    assert AlertFeed.condition_states(["system.target.resolved", "system.target"], opts) == %{"system.target.resolved" => :firing, "system.target" => :firing}
  end

  defp enqueue(store, target) do
    AgentQueueStore.enqueue(store, %{target_issue_identifier: target, source: :executor, category: :operator_message, event_type: :message, body: %{text: target}})
  end

  defp calls(mfas, fun) do
    parent = self()

    worker =
      spawn_link(fn ->
        receive do
          :run -> send(parent, {:result, self(), fun.()})
        end

        receive do
          :stop -> :ok
        end
      end)

    Enum.each(mfas, fn {module, _, _} = mfa ->
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(mfa, true, [:local])
    end)

    :erlang.trace(worker, true, [:call, {:tracer, parent}])

    try do
      send(worker, :run)
      result = receive do: ({:result, ^worker, result} -> result)
      delivery = :erlang.trace_delivered(worker)
      receive do: ({:trace_delivered, ^worker, ^delivery} -> :ok)
      {result, collect_calls(worker, [])}
    after
      :erlang.trace(worker, false, [:call])
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local]))
      send(worker, :stop)
    end
  end

  defp collect_calls(worker, calls) do
    receive do
      {:trace, ^worker, :call, mfa} -> collect_calls(worker, [mfa | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
