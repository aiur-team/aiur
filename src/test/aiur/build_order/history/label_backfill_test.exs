defmodule Aiur.BuildOrder.History.LabelBackfillTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  # Shared fake stores keep the restart and request-order scenarios in one fixture.
  alias Aiur.BuildOrder.History.LabelBackfill
  alias Aiur.BuildOrder.History.LabelBackfill.Checkpoint

  defmodule Tracker do
    def ensure_labels(labels), do: request({:ensure, labels})
    def add_label(n, label), do: request({:label, n, label})

    defp request(message) do
      send(Process.get(:test_owner), {:request, message})
      send(Process.get(:test_owner), {:writer, message, Process.get(:aiur_ticket_writer)})

      case Process.get(:tracker_result, :ok) do
        :crash_label when elem(message, 0) == :label ->
          Process.exit(self(), :kill)

        :crash_label ->
          :ok

        {:block_ensure, owner} when elem(message, 0) == :ensure ->
          send(owner, {:blocked, self()})

          receive do
            :release -> :ok
          after
            5_000 -> {:error, :test_timeout}
          end

        {:block_ensure, _} ->
          :ok

        result ->
          result
      end
    end
  end

  setup do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    dir = Path.join(System.tmp_dir!(), "label-writes-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    {:ok, fixture} =
      Agent.start_link(fn ->
        %{
          now: now,
          owners: %{1 => %{feature: "h", confirmed: true}},
          projection: %{1 => :held_backfill},
          labels: [],
          lifecycle: :closed,
          health: :healthy,
          result: :ok,
          mark_result: :ok,
          overrides: %{},
          catalog: [%{key: "bugs", labels: ["bug"]}]
        }
      end)

    owner = self()
    get = fn key -> Agent.get(fixture, &Map.fetch!(&1, key)) end

    readers = %{
      tracker_supported: fn -> true end,
      features: fn -> {:ok, %{owners: get.(:owners)}} end,
      projection: fn _ ->
        case get.(:projection) do
          {:error, _} = error -> error
          states -> {:ok, states}
        end
      end,
      owner: fn n ->
        case get.(:owners)[n] do
          nil -> :none
          value -> {:ok, value}
        end
      end,
      overrides: fn -> {:ok, get.(:overrides), %{state: :healthy}} end,
      settings: fn -> {:ok, %{build_order: %{general_epics: get.(:catalog)}}} end,
      history: fn numbers ->
        rows = Enum.map(numbers, &%{number: &1, labels: get.(:labels), lifecycle: %{state: get.(:lifecycle)}, observed_at: get.(:now)})
        {:ok, rows, %{state: get.(:health)}}
      end,
      health: fn -> %{state: get.(:health), observed_at: get.(:now)} end,
      mark: fn slug, n, times ->
        send(owner, {:mark, slug, n, times})
        get.(:mark_result)
      end
    }

    writer = fn path, bytes, opts ->
      Process.put(:test_owner, owner)
      Process.put(:tracker_result, get.(:result))
      send(owner, {:saved, Jason.decode!(bytes)})
      Aiur.Fs.atomic_write(path, bytes, opts)
    end

    opts = [
      name: nil,
      repository: "o/r",
      state_path: Path.join(dir, "writes.json"),
      clock: fn -> get.(:now) end,
      readers: readers,
      tracker: Tracker,
      writer: writer,
      sync: fn -> :ok end,
      tick_ms: 3_600_000,
      budget_settings: fn -> %{agent_core_limit_per_hour: 250} end,
      max_writes_per_minute: 20,
      agent_workspace: ""
    ]

    %{opts: opts, fixture: fixture, now: now}
  end

  defp boot(opts), do: start_supervised!({LabelBackfill, opts})
  defp update(fixture, fields), do: Agent.update(fixture, &Map.merge(&1, fields))

  defp requests do
    receive do
      {:request, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  defp start(server, extra \\ []), do: LabelBackfill.start([server: server, expect: 30] ++ extra)
  defp tick(server), do: LabelBackfill.tick(server: server)

  test "plan counts requests separately and start binds expect including label creation", ctx do
    server = boot(ctx.opts)
    plan = LabelBackfill.plan(server: server)
    assert %{writes: %{feature: 1, epic: 0}, ensure: 1, total: 2, hours: 1} = plan
    output = capture_io(fn -> Aiur.AgentControlCLI.history_label_writes(action: :plan, server: server, json: true) end)
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert output |> String.split("\n") |> hd() |> Jason.decode!() |> Map.fetch!("total") == 2
    assert {:error, {:expect_exceeded, 2}} = LabelBackfill.start(server: server, expect: 1)
    assert {:error, {:maximum, 125}} = start(server, per_hour: 126)
    assert requests() == []
    assert %{run: %{state: :running}} = start(server)
    assert %{run: %{state: :finished}, counts: %{written: 1}, requests_last_hour: 2} = tick(server)
    assert requests() == [{:ensure, ["feature:h"]}, {:label, "1", "feature:h"}]
    assert_received {:mark, "h", 1, %{written_at: at, seen_at: at}}
    assert at == ctx.now
  end

  test "start reads the current effective Core ceiling", ctx do
    update(ctx.fixture, %{budget_limit: 250})
    settings = fn -> %{agent_core_limit_per_hour: Agent.get(ctx.fixture, & &1.budget_limit)} end
    server = boot(Keyword.put(ctx.opts, :budget_settings, settings))
    update(ctx.fixture, %{budget_limit: 4})
    assert {:error, {:maximum, 2}} = start(server, per_hour: 3)
    assert requests() == []
    update(ctx.fixture, %{budget_limit: 0})
    assert {:error, {:maximum, 125}} = start(server, per_hour: 126)
  end

  test "unconfirmed and other projection states stay out; unknown sources never become zero", ctx do
    server = boot(ctx.opts)
    update(ctx.fixture, %{owners: %{1 => %{feature: "h", confirmed: false}}})
    assert %{total: 0, skipped: %{unconfirmed: 1}} = LabelBackfill.plan(server: server)
    update(ctx.fixture, %{projection: %{1 => :exempt}})
    assert %{total: 0} = LabelBackfill.plan(server: server)
    update(ctx.fixture, %{projection: {:error, :projection_state_unavailable}})
    assert %{total: :unknown, writes: %{feature: :unknown}, unknown: [:projection]} = LabelBackfill.plan(server: server)
    assert {:error, {:plan_unknown, [:projection]}} = start(server)

    for reason <- [:projection_not_running, :registry_unavailable] do
      update(ctx.fixture, %{projection: {:error, reason}})
      assert %{total: :unknown, writes: %{feature: :unknown}, unknown: [:projection]} = LabelBackfill.plan(server: server)
    end

    update(ctx.fixture, %{owners: %{1 => %{feature: "h", confirmed: true}}, projection: %{1 => :held_backfill}, labels: :unknown})
    assert %{total: :unknown, writes: %{feature: :unknown}, deferred: %{labels_unknown: 1}} = LabelBackfill.plan(server: server)
    assert requests() == []
  end

  test "epic matcher is opt in and empty matchers are counted", ctx do
    update(ctx.fixture, %{overrides: %{2 => %{epic: "bugs", confirmed: true}, 3 => %{epic: "empty", confirmed: true}}})
    server = boot(ctx.opts)
    assert %{writes: %{epic: 0}} = LabelBackfill.plan(server: server)
    assert %{writes: %{epic: 1}, skipped: %{no_matcher: 1}, total: 3} = LabelBackfill.plan(server: server, epic_labels: true)
  end

  test "a shared feature and epic label preserves both outcomes and the feature handoff", ctx do
    update(ctx.fixture, %{overrides: %{1 => %{epic: "bugs", confirmed: true}}, catalog: [%{key: "bugs", labels: ["feature:h"]}]})
    server = boot(ctx.opts)
    assert %{total: 3, writes: %{feature: 1, epic: 1}} = LabelBackfill.plan(server: server, epic_labels: true)
    start(server, epic_labels: true)
    assert %{counts: %{written: 2}, requests_last_hour: 3} = tick(server)
    assert Enum.sort(requests()) == Enum.sort([{:ensure, ["feature:h"]}, {:label, "1", "feature:h"}, {:label, "1", "feature:h"}])
    assert_received {:mark, "h", 1, %{written_at: at}}
    assert at == ctx.now
    stop_supervised!(LabelBackfill)
    server = boot(ctx.opts)
    assert %{counts: %{written: 2}, requests_last_hour: 3} = LabelBackfill.status(server: server)
    assert requests() == []
  end

  test "rolling bucket counts failed requests and survives restart", ctx do
    update(ctx.fixture, %{result: {:error, {:github, :http, %{status: 500}}}})
    server = boot(ctx.opts)
    start(server, per_hour: 3)
    tick(server)
    tick(server)
    tick(server)
    assert length(requests()) == 3
    stop_supervised!(LabelBackfill)
    server = boot(ctx.opts)
    assert %{requests_last_hour: 3} = tick(server)
    assert requests() == []
    update(ctx.fixture, %{now: DateTime.add(ctx.now, 3660)})
    tick(server)
    assert length(requests()) == 1
    assert %{counts: %{failed: 1}, run: %{state: :finished}} = tick(server)
    tick(server)
    assert length(requests()) == 1
  end

  test "reservation is persisted before the tracker call and failed persistence cancels it", ctx do
    server = boot(ctx.opts)
    start(server, per_hour: 1)
    tick(server)
    messages = drain([])
    reservation = Enum.find_index(messages, &match?({:saved, %{"window" => [_]}}, &1))
    request = Enum.find_index(messages, &match?({:request, _}, &1))
    assert is_integer(reservation) and reservation < request
    stop_supervised!(LabelBackfill)
    opts = Keyword.put(ctx.opts, :writer, fn _, _, _ -> {:error, :enospc} end)
    server = boot(opts)
    assert tick_after_expiry(server, ctx) in [%{state: :unavailable, reason: :checkpoint_write_failed}, {:error, :checkpoint_write_failed}]
    assert requests() == []
  end

  defp tick_after_expiry(server, ctx) do
    update(ctx.fixture, %{now: DateTime.add(ctx.now, 3660)})
    tick(server)
  end

  defp drain(acc) do
    receive do
      message -> drain(acc ++ [message])
    after
      0 -> acc
    end
  end

  test "local hold survives restart and is preserved by pause and resume", ctx do
    reset = DateTime.add(ctx.now, 600)
    update(ctx.fixture, %{result: {:error, {:github, :local_hold, %{hold: %{reset_at: reset}}}}})
    server = boot(ctx.opts)
    start(server)
    assert %{writes: :held, run: %{hold_until: ^reset}} = tick(server)
    assert length(requests()) == 1
    stop_supervised!(LabelBackfill)
    server = boot(ctx.opts)
    LabelBackfill.pause(server: server)
    LabelBackfill.resume(server: server)
    tick(server)
    assert requests() == []
    update(ctx.fixture, %{now: reset, result: :ok})
    tick(server)
    assert requests() == [{:ensure, ["feature:h"]}, {:label, "1", "feature:h"}]
  end

  test "auth and forbidden stop until explicit resume", ctx do
    server = boot(ctx.opts)
    update(ctx.fixture, %{result: {:error, {:github, :http, %{status: 403}}}})
    start(server)
    assert %{run: %{state: :stopped, stop_reason: :forbidden}} = tick(server)
    for _ <- 1..3, do: tick(server)
    assert length(requests()) == 1
    update(ctx.fixture, %{result: :ok})
    LabelBackfill.resume(server: server)
    assert %{run: %{state: :finished}} = tick(server)
    assert length(requests()) == 2
  end

  test "pre-write owner re-read skips moved membership", ctx do
    readers = Map.put(ctx.opts[:readers], :owner, fn _ -> {:ok, %{feature: "other", confirmed: true}} end)
    server = boot(Keyword.put(ctx.opts, :readers, readers))
    start(server)
    assert %{counts: %{skipped: 1}} = tick(server)
    assert requests() == []
  end

  test "mark failures retry only the mark; departed members are terminal", ctx do
    update(ctx.fixture, %{mark_result: {:error, :projection_state_unavailable}})
    server = boot(ctx.opts)
    start(server)
    assert %{counts: %{written_unmarked: 1}} = tick(server)
    assert length(requests()) == 2
    update(ctx.fixture, %{mark_result: {:error, {:not_member, [1]}}})
    assert %{counts: %{written: 1}, run: %{state: :finished}} = tick(server)
    tick(server)
    assert requests() == []
  end

  test "present labels repair a crash before projection mark without a request", ctx do
    update(ctx.fixture, %{labels: ["Feature:H"]})
    server = boot(ctx.opts)
    assert %{total: 0} = LabelBackfill.plan(server: server)
    start(server)
    assert %{counts: %{already_present: 1}} = tick(server)
    assert_received {:mark, "h", 1, %{written_at: nil, seen_at: at}}
    assert at == ctx.now
    assert requests() == []
  end

  test "corrupt checkpoint remains unavailable across boots instead of forgetting tokens", ctx do
    File.write!(ctx.opts[:state_path], "{bad")
    server = boot(ctx.opts)
    assert {:error, :checkpoint_corrupt} = LabelBackfill.status(server: server)
    assert {:error, :checkpoint_corrupt} = start(server)
    output = capture_io(fn -> assert Aiur.HistoryLabelWritesCLI.run(action: :status, server: server, json: true) == 1 end)
    assert Jason.decode!(output) == %{"state" => "unavailable", "reason" => ":checkpoint_corrupt"}
    human = capture_io(fn -> assert Aiur.HistoryLabelWritesCLI.run(action: :status, server: server) == 1 end)
    assert human == "history label-writes: unavailable (:checkpoint_corrupt)\n"
    assert File.read!(ctx.opts[:state_path] <> ".corrupt") == "{bad"
    stop_supervised!(LabelBackfill)
    server = boot(ctx.opts)
    assert {:error, :checkpoint_corrupt} = LabelBackfill.status(server: server)
    assert requests() == []
  end

  test "unknown version repository and symlink refuse loading", ctx do
    path = ctx.opts[:state_path]

    for {data, reason} <- [{%{v: 2}, :checkpoint_version}, {%{repository: "other/repo"}, :repository_mismatch}] do
      File.write!(path, Jason.encode!(data))
      assert {:error, ^reason} = Checkpoint.load(path, "o/r")
    end

    File.rm!(path)
    File.ln_s!("missing", path)
    assert {:error, :unsafe_checkpoint} = Checkpoint.load(path, "o/r")
  end

  test "status carries ages and preserves unavailable history as unknown", ctx do
    server = boot(ctx.opts)
    start(server)
    tick(server)
    update(ctx.fixture, %{now: DateTime.add(ctx.now, 720), health: :unavailable})
    status = LabelBackfill.status(server: server)
    assert status.last_write.age_ms == 720_000
    assert status.history == %{observed_at: :unknown, age_ms: :unknown, freshness: :unknown}
    rendered = status |> Aiur.JSONSafe.normalize() |> Aiur.HistoryLabelWritesCLI.render()
    assert rendered =~ "12m ago"
    assert rendered =~ "history unknown"
  end

  test "a crash after a label request retains its token and repairs from History", ctx do
    update(ctx.fixture, %{result: :crash_label})
    server = start_supervised!(Supervisor.child_spec({LabelBackfill, ctx.opts}, restart: :temporary))
    monitor = Process.monitor(server)
    start(server, per_hour: 2)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 2_000
    assert requests() == [{:ensure, ["feature:h"]}, {:label, "1", "feature:h"}]
    update(ctx.fixture, %{result: :ok, labels: ["feature:h"]})
    server = boot(ctx.opts)
    assert %{requests_last_hour: 2, counts: %{already_present: 1}} = tick(server)
    assert_received {:mark, "h", 1, %{written_at: nil, seen_at: seen}}
    assert seen == ctx.now
    assert requests() == []
  end

  test "a pause queued during label creation prevents the subsequent label request", ctx do
    update(ctx.fixture, %{result: {:block_ensure, self()}})
    server = boot(ctx.opts)
    start(server)
    assert_receive {:blocked, ^server}, 2_000
    caller = self()

    pause =
      Task.async(fn ->
        send(caller, :pausing)
        LabelBackfill.pause(server: server)
      end)

    assert_receive :pausing, 2_000
    # Wait until the real call is queued, then release the in-flight request.
    wait_for_pause(server)
    send(server, :release)
    assert %{run: %{state: :paused}} = Task.await(pause)
    assert %{run: %{state: :paused}} = tick(server)
    assert requests() == [{:ensure, ["feature:h"]}]
  end

  defp wait_for_pause(server, attempts \\ 1000)
  defp wait_for_pause(_server, 0), do: flunk("pause call was not queued")

  defp wait_for_pause(server, attempts) do
    {:messages, messages} = Process.info(server, :messages)
    if Enum.any?(messages, &match?({:"$gen_call", _, :pause}, &1)), do: :ok, else: wait_for_pause(server, attempts - 1)
  end

  test "supervision keeps the optional writer before the Executor binding" do
    opts = [interactive_cli?: false, headless?: true, dashboard?: false, tailscale_funnel?: false]
    enabled = Aiur.Application.child_specs([recording?: true] ++ opts)
    assert Enum.map(Enum.take(enabled, -2), &Supervisor.child_spec(&1, []).id) == [LabelBackfill, Aiur.Executor.Session]
    disabled = Aiur.Application.child_specs([recording?: false] ++ opts)
    refute Enum.any?(disabled, &(Supervisor.child_spec(&1, []).id == LabelBackfill))
  end

  test "minute pacing counts ensure and label requests and survives restart", ctx do
    update(ctx.fixture, %{owners: %{1 => %{feature: "h", confirmed: true}, 2 => %{feature: "h", confirmed: true}}, projection: %{1 => :held_backfill, 2 => :held_backfill}})
    opts = Keyword.put(ctx.opts, :max_writes_per_minute, 2)
    server = boot(opts)
    start(server, per_hour: 60)
    assert %{requests_last_hour: 2, counts: %{written: 1, pending: 1}} = tick(server)
    assert requests() == [{:ensure, ["feature:h"]}, {:label, "1", "feature:h"}]
    assert_received {:writer, {:ensure, ["feature:h"]}, :history_label_backfill}
    assert_received {:writer, {:label, "1", "feature:h"}, :history_label_backfill}
    stop_supervised!(LabelBackfill)
    update(ctx.fixture, %{now: DateTime.add(ctx.now, 59)})
    server = boot(opts)
    tick(server)
    assert requests() == []
    update(ctx.fixture, %{now: DateTime.add(ctx.now, 60)})
    assert %{requests_last_hour: 3, counts: %{written: 2}, run: %{state: :finished}} = tick(server)
    assert requests() == [{:label, "2", "feature:h"}]
  end

  test "a batch plans once while retaining each pre-write owner check", ctx do
    owners = Map.new(1..3, &{&1, %{feature: "h", confirmed: true}})
    update(ctx.fixture, %{owners: owners, projection: Map.new(1..3, &{&1, :held_backfill})})
    parent = self()
    readers = ctx.opts[:readers]

    features = fn ->
      send(parent, :planned)
      readers.features.()
    end

    owner = fn n ->
      send(parent, {:owner_read, n})
      readers.owner.(n)
    end

    server = boot(Keyword.put(ctx.opts, :readers, %{readers | features: features, owner: owner}))
    start(server)
    tick(server)
    messages = drain([])
    assert Enum.count(messages, &(&1 == :planned)) in 2..3
    for n <- 1..3, do: assert({:owner_read, n} in messages)
    assert Enum.count(messages, &match?({:request, _}, &1)) == 4
  end

  test "workspace refusal applies at server boundary too", ctx do
    server = boot(Keyword.put(ctx.opts, :agent_workspace, "/agent"))
    assert {:error, :agent_workspace_refused} = start(server)
    assert {:error, :agent_workspace_refused} = LabelBackfill.resume(server: server)
    assert %{run: %{state: :idle}} = LabelBackfill.status(server: server)
    assert requests() == []
  end
end
