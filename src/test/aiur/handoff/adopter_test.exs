defmodule Aiur.Handoff.AdopterTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.Handoff, as: Runner
  alias Aiur.Handoff.{Adopter, Compatibility, Record, Report}
  alias Aiur.Orchestrator.{OrphanedWorkers, StartupClaimReconciler, State, StatusReport}

  setup do
    dir = Path.join(System.tmp_dir!(), "adopter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "adoption protects claims, preserves counters and original duration above the slot cap", %{dir: dir} do
    agent = agent(dir, "one")
    record = record([agent])
    assert :ok = Record.write(record, dir: dir)
    parent = self()

    runner = fn _agent, 2, recipient, _opts ->
      send(recipient, {:handoff_adopted, self(), {:ok, %{metadata: %{codex_app_server_pid: "123"}}}})

      receive do
        :handoff_continue -> send(parent, {:continued, self()})
      end

      receive do
        :stop -> :ok
      end
    end

    state = Adopter.adopt(%State{max_concurrent_agents: 0}, options(dir, runner: runner))
    assert_receive {:continued, pid}, 1000
    on_exit(fn -> send(pid, :stop) end)
    assert state.running["one"].pid == pid
    assert state.running["one"].adopted_from == "restart"
    assert {:ok, %{adopted: [outcome], fallback: []}} = Report.latest(dir: dir)
    assert outcome["provider_pid_before"] == "123"
    assert outcome["provider_pid_after"] == "123"
    assert outcome["session_id_before"] == "session-one"
    assert outcome["session_id_after"] == "session-one"
    assert state.running["one"].agent_total_tokens == 27
    assert State.effective_runtime_seconds(state.running["one"], DateTime.utc_now()) >= 119
    assert state.claimed == MapSet.new(["one"])
    assert state.dispatch_recovery.codex_thrash_budget["one"] == %{attempts: 3}
    assert OrphanedWorkers.stop_untracked_runners(state).running == state.running

    {retained, [issue]} =
      StartupClaimReconciler.reconcile(state, [state.running["one"].issue],
        grace_ms: 0,
        ownership_fun: fn _ -> :none end,
        read_boot_marker_fun: fn -> {:ok, nil} end,
        mark_boot_marker_fun: fn _ -> :ok end,
        update_issue_state_fun: fn _, _, _ -> flunk("adoption must keep the original claim") end
      )

    assert issue.state == "in-progress"
    assert retained.claimed == state.claimed
    assert [%{adopted_from: "restart"}] = StatusReport.snapshot_payload(state).running
    assert :none = Record.read(dir: dir)
    assert Adopter.adopt(state, options(dir)).running == state.running
  end

  test "unknown schema stops every listed agent and consumes one fallback outcome each", %{dir: dir} do
    agents = [agent(dir, "one"), agent(dir, "two")]
    Aiur.JsonStore.write!(Record.path(dir: dir), %{record(agents) | "handoff_schema" => 99})
    parent = self()
    opts = options(dir, stop_agent: fn agent -> send(parent, {:stopped, agent["identifier"]}) end, emit_alert: fn topic, _ -> send(parent, {:alert, topic}) end)
    assert Adopter.adopt(%State{}, opts).running == %{}
    assert_receive {:stopped, "one"}, 1000
    assert_receive {:stopped, "two"}, 1000
    assert_receive {:alert, "system.handoff.incompatible"}, 1000
    assert_received {:alert, "system.restart.handoff.completed"}
    assert_received {:alert, "system.restart.handoff.fallback"}
    refute_receive {:alert, _}, 20
    assert {:ok, %{"outcome" => outcomes}} = Aiur.JsonStore.read(Record.path(dir: dir) <> ".consumed")
    assert Enum.map(outcomes, & &1["reason"]) == [":schema", ":schema"]
    Adopter.adopt(%State{}, opts)
    refute_receive {:stopped, _}, 20
    refute_received {:alert, _}
  end

  test "config changes and missing relays fall back independently", %{dir: dir} do
    bad_config = Map.put(agent(dir, "changed"), "config_fingerprint", "different")
    gone = put_in(agent(dir, "gone"), ["transport", "directory"], "missing")
    good = agent(dir, "good")
    assert :ok = Record.write(record([bad_config, gone, good]), dir: dir)
    parent = self()

    runner = fn _, _, recipient, _ ->
      send(recipient, {:handoff_adopted, self(), {:ok, %{}}})

      receive do
        :handoff_continue -> send(parent, {:continued, self()})
      end

      receive do
        :stop -> :ok
      end
    end

    state =
      Adopter.adopt(
        %State{},
        options(dir,
          runner: runner,
          stop_agent: fn a -> send(parent, {:stopped, a["identifier"]}) end,
          issue_state_fetcher: fn ids ->
            send(parent, {:fallback_batch, ids})
            {:ok, Enum.map(ids, &%Aiur.Issue{id: &1, identifier: &1, title: "existing", state: "in-progress"})}
          end
        )
      )

    assert Map.keys(state.running) == ["good"]
    assert_receive {:continued, pid}, 1000
    send(pid, :stop)
    assert_receive {:stopped, "changed"}, 1000
    assert_receive {:stopped, "gone"}, 1000
    assert_receive {:fallback_batch, ["changed", "gone"]}, 1000
    assert {:ok, %{"outcome" => [changed, gone, good]}} = Aiur.JsonStore.read(Record.path(dir: dir) <> ".consumed")
    assert changed["reason"] == ":config_changed"
    assert gone["reason"] == ":relay_gone"
    assert good["status"] == "adopted"
  end

  test "an agent past the slot cap falls back instead of being adopted (#4683)", %{dir: dir} do
    assert :ok = Record.write(record([agent(dir, "kept"), agent(dir, "over")]), dir: dir)
    parent = self()

    runner = fn _, _, recipient, _ ->
      send(recipient, {:handoff_adopted, self(), {:ok, %{}}})

      receive do
        :handoff_continue -> send(parent, {:continued, self()})
      end

      receive do
        :stop -> :ok
      end
    end

    issues = Enum.map(["kept", "over"], &%Aiur.Issue{id: &1, identifier: &1, title: "existing", state: "in-progress"})
    fetch = fn ids -> {:ok, Enum.filter(issues, &(&1.id in ids))} end

    state =
      Adopter.adopt(
        %State{max_concurrent_agents: 1},
        options(dir,
          runner: runner,
          stop_agent: fn a -> send(parent, {:stopped, a["identifier"]}) end,
          issue_state_fetcher: fetch
        )
      )

    assert Map.keys(state.running) == ["kept"]
    assert_receive {:continued, pid}, 1000
    send(pid, :stop)
    assert_receive {:stopped, "over"}, 1000
    assert state.retry_attempts["over"]
    assert {:ok, %{"outcome" => [_kept, over]}} = Aiur.JsonStore.read(Record.path(dir: dir) <> ".consumed")
    assert over["reason"] == ":max_concurrent_agents_reached"
  end

  test "fallback re-reads ticket state and skips tickets that moved to ci-wait", %{dir: dir} do
    pending = agent(dir, "pending")
    issue = %Aiur.Issue{id: "pending", identifier: "pending", title: "existing", state: "ci-wait"}
    pending = Map.put(pending, "issue", %{"state" => "in-progress"})
    assert :ok = Record.write(record([pending]), dir: dir)
    parent = self()

    runner = fn _, _, recipient, _ ->
      send(recipient, {:handoff_adopted, self(), {:error, :mergeability_unknown}})
    end

    state =
      Adopter.adopt(
        %State{},
        options(dir,
          runner: runner,
          issue_state_fetcher: fn ["pending"] ->
            send(parent, :state_refetched)
            {:ok, [issue]}
          end,
          stop_agent: fn _ -> send(parent, :provider_stopped) end
        )
      )

    assert_receive :state_refetched, 1000
    assert_receive :provider_stopped, 1000

    assert {:ok, %{"outcome" => [%{"status" => "fallback", "reason" => ":mergeability_unknown"}]}} =
             Aiur.JsonStore.read(Record.path(dir: dir) <> ".consumed")

    refute Map.has_key?(state.retry_attempts, "pending")
    assert state.claimed == MapSet.new()
    assert {:ok, %{fallback: [%{"reason" => ":mergeability_unknown"}]}} = Report.latest(dir: dir)
  end

  test "fallback does not redispatch when the current ticket state cannot be fetched", %{dir: dir} do
    agent = agent(dir, "unavailable")
    assert :ok = Record.write(record([agent]), dir: dir)
    parent = self()
    runner = fn _, _, recipient, _ -> send(recipient, {:handoff_adopted, self(), {:error, :mergeability_unknown}}) end

    state =
      Adopter.adopt(
        %State{},
        options(dir,
          runner: runner,
          stop_agent: fn _ -> send(parent, :provider_stopped) end,
          issue_state_fetcher: fn _ ->
            send(parent, :state_refetched)
            {:error, :offline}
          end
        )
      )

    assert_receive :state_refetched, 1000
    assert_receive :provider_stopped, 1000
    refute Map.has_key?(state.retry_attempts, "unavailable")
    assert state.claimed == MapSet.new()
  end

  test "fallback seeds retry capacity from the freshly fetched state", %{dir: dir} do
    stale = Map.put(agent(dir, "one"), "issue", %{"state" => "in-progress"})
    current = %Aiur.Issue{id: "one", identifier: "one", title: "existing", state: "todo"}
    assert :ok = Record.write(record([stale]), dir: dir)
    runner = fn _, _, recipient, _ -> send(recipient, {:handoff_adopted, self(), {:error, :relay_gone}}) end

    state =
      Adopter.adopt(
        %State{},
        options(dir,
          runner: runner,
          stop_agent: fn _ -> :ok end,
          issue_state_fetcher: fn ["one"] -> {:ok, [current]} end
        )
      )

    assert state.retry_attempts["one"].issue_state == "todo"
  end

  test "consume failure stops staged runners before they resume", %{dir: dir} do
    assert :ok = Record.write(record([agent(dir, "one")]), dir: dir)
    File.mkdir_p!(Record.path(dir: dir) <> ".consumed")
    parent = self()

    runner = fn _, _, recipient, _ ->
      send(parent, {:staged, self()})
      send(recipient, {:handoff_adopted, self(), {:ok, %{}}})

      receive do
        :handoff_continue -> send(parent, :resumed_before_consume)
      end
    end

    issue = %Aiur.Issue{id: "one", identifier: "one", title: "existing", state: "in-progress"}

    state =
      Adopter.adopt(
        %State{},
        options(dir,
          runner: runner,
          stop_agent: fn _ -> :ok end,
          issue_state_fetcher: fn ["one"] -> {:ok, [issue]} end
        )
      )

    assert_receive {:staged, pid}, 1000
    refute Process.alive?(pid)
    assert state.running == %{}
    assert state.retry_attempts["one"].prior_work
    refute_receive :resumed_before_consume, 20
  end

  test "compatibility checks protocol, identity and loss before mutable configuration", %{dir: dir} do
    agent = agent(dir, "one")
    opts = options(dir)
    assert :ok = Compatibility.check(agent, record([agent]), opts)
    assert {:error, :relay_protocol} = Compatibility.check(put_in(agent, ["transport", "protocol"], 99), record([]), opts)
    assert {:error, :relay_gone} = Compatibility.check(put_in(agent, ["transport", "spawn_nonce"], "other"), record([]), opts)
    lossy = Keyword.put(opts, :relay_probe, fn _ -> {:ok, Map.put(hello(), "lossy", true)} end)
    assert {:error, :relay_lossy} = Compatibility.check(agent, record([]), lossy)
  end

  defp options(dir, extra \\ []) do
    Keyword.merge(
      [
        dir: dir,
        generation: 2,
        config_fingerprint: "config",
        emit_alert: fn _name, _options -> :ok end,
        relay_probe: fn
          "missing" -> {:error, :enoent}
          _ -> {:ok, hello()}
        end
      ],
      extra
    )
  end

  defp hello, do: %{"protocol" => 1, "spawn_nonce" => "nonce", "provider_pid" => 123, "relay_id" => "relay", "lossy" => false}

  defp agent(dir, id) do
    issue = %Aiur.Issue{id: id, identifier: id, title: "existing", state: "in-progress"}
    entry = %{identifier: id, session_id: "session-#{id}", issue: issue, started_at: DateTime.add(DateTime.utc_now(), -120), agent_total_tokens: 27, worker_host: nil, turn_count: 2}

    %{
      "issue_id" => id,
      "identifier" => id,
      "workspace" => dir,
      "backend" => "codex",
      "running_entry" => Runner.encode(entry),
      "transport" => Map.merge(hello(), %{"kind" => "relay", "directory" => dir}),
      "dispatch_attempts" => Runner.encode(%{attempts: 3})
    }
  end

  defp record(agents) do
    %{
      "handoff_schema" => 1,
      "handoff_id" => "restart",
      "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "from_version" => "test",
      "generation" => 1,
      "config_fingerprint" => "config",
      "agents" => agents
    }
  end
end
