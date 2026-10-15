defmodule Aiur.MainWatchTest do
  use Aiur.TestSupport
  alias Aiur.CI.FailureDigest
  alias Aiur.Events.Exchange
  alias Aiur.MainWatch
  alias Aiur.MainWatch.{Persistence, State}

  setup do
    unless Process.whereis(Aiur.TaskSupervisor), do: start_supervised!({Task.Supervisor, name: Aiur.TaskSupervisor})
    :ok
  end

  test "poll stays responsive and persisted publication survives restart without duplicate" do
    parent = self()

    emit = fn topic, payload ->
      send(parent, {:emitted, topic, payload})
      {:error, :offline}
    end

    server = launch(Persistence.empty(), emit_fun: emit)
    assert MainWatch.state(server).status == :unknown
    persisted = finish_poll(server, {:ok, result([observation("red", 1)])})
    assert [{"system.main.ci.failed", %{sha: "red"}}] = persisted.pending
    assert_received {:emitted, "system.main.ci.failed", %{sha: "red", failing_tests: :unknown}}
    stop_supervised!(MainWatch)
    server = launch(persisted)
    persisted = finish_poll(server, {:ok, result([observation("red", 1)])})
    assert persisted.pending == []
    assert MainWatch.state(server).status == :red
    assert_received {:emitted, "system.main.ci.failed", %{sha: "red"}}
    refute_received {:emitted, _, _}
  end

  test "pending publication replays after restart even when the poll is unavailable" do
    observation = observation("red", 1)
    {state, pending} = State.observe(State.new(), observation, 1)
    server = launch(%{Persistence.empty() | state: state, pending: pending})
    persisted = finish_poll(server, {:error, :github_offline})
    assert persisted.pending == []
    assert persisted.unavailable
    assert_received {:emitted, "system.main.ci.failed", %{sha: "red"}}
    assert_received {:emitted, "system.main.ci.unavailable", %{reason: ":github_offline"}}
    refute_received {:emitted, _, _}
  end

  test "unavailable watcher keeps a sanitized auth diagnostic through restart" do
    reason = {:github, :auth, %{status: 401, caller: "main_watch_commits", credential: "github_app_installation"}}
    server = launch(Persistence.empty())
    persisted = finish_poll(server, {:error, reason})
    assert %{watcher: :unavailable, last_error: "GitHub rejected github_app_installation with HTTP 401 during main_watch_commits"} = MainWatch.state(server)
    stop_supervised!(MainWatch)
    server = launch(persisted)
    assert MainWatch.state(server).last_error == "GitHub rejected github_app_installation with HTTP 401 during main_watch_commits"
    green = %{observation("recovered", 2) | checks: [%{name: "test", conclusion: "success"}]}
    finish_poll(server, {:ok, result([green])})
    assert %{watcher: :running, status: :green, sha: "recovered", last_error: nil} = MainWatch.state(server)
    stop_supervised!(MainWatch)
  end

  test "known flake without Actions write raises capability attention once" do
    digest = %FailureDigest{signature: "flake", flake_only: true, tests: [%{identity: "flaky", classification: :known_flake}]}
    observation = %{observation("flake", 1) | digest: digest}
    server = launch(Persistence.empty())
    finish_poll(server, {:ok, result([observation])})
    assert_received {:emitted, "system.main.ci.flaked", %{sha: "flake"}}
    assert_received {:emitted, "system.main.ci.flake_rerun", %{outcome: %{status: "error", reason: ":actions_write_unavailable"}}}
    GenServer.cast(server, :reconcile)
    finish_poll(server, {:ok, result([observation])})
    refute_received {:emitted, _, _}
  end

  test "canary rerun failure alerts once within a window and again next window" do
    parent = self()
    clock = start_supervised!({Agent, fn -> 46 * 60_000 end})

    server =
      launch(%{Persistence.empty() | started_at: 0},
        config: %{workflows: [], canary_minutes: 45},
        now_fun: fn -> Agent.get(clock, & &1) end,
        rerun_fun: fn id, _ ->
          send(parent, {:rerun, id})
          {:error, :denied}
        end
      )

    result = %{result([]) | actions_write: true, runs: [run("cancelled", 0)]}
    finish_poll(server, {:ok, result})
    assert_received {:rerun, 3}
    assert_received {:emitted, "system.main.ci.canary", %{window: 1, outcome: %{status: "error", reason: ":denied"}}}
    GenServer.cast(server, :reconcile)
    finish_poll(server, {:ok, result})
    refute_received {:rerun, _}
    refute_received {:emitted, _, _}
    Agent.update(clock, fn _ -> 92 * 60_000 end)
    GenServer.cast(server, :reconcile)
    finish_poll(server, {:ok, result})
    assert_received {:rerun, 3}
    assert_received {:emitted, "system.main.ci.canary", %{window: 2}}
  end

  test "an older commit completion refreshes the canary while newest commit owns CI state" do
    now = 46 * 60_000
    server = launch(%{Persistence.empty() | started_at: 0}, config: %{workflows: [], canary_minutes: 45}, now_fun: fn -> now end)
    newer = observation("newest", 1)
    older = %{observation("older", now - 1_000) | checks: [%{name: "test", conclusion: "success"}]}
    runs = [%{run("success", now - 1_000) | sha: "older"}, run("cancelled", 0)]
    persisted = finish_poll(server, {:ok, %{result([older, newer]) | runs: runs}})
    assert persisted.last_completed_at == now - 1_000
    assert MainWatch.state(server).sha == "newest"
    assert_received {:emitted, "system.main.ci.failed", %{sha: "newest"}}
    refute_received {:emitted, "system.main.ci.canary", _}
  end

  test "historical red never alerts when newest completed SHA is green" do
    server = launch(Persistence.empty())
    green = %{observation("green", 2) | checks: [%{name: "test", conclusion: "success"}]}
    persisted = finish_poll(server, {:ok, result([observation("red", 1), green])})
    assert MainWatch.state(server).status == :green
    assert Enum.map(persisted.state.history, & &1.sha) == ["red", "green"]
    assert persisted.state.emitted_signatures == []
    refute_received {:emitted, _, _}
  end

  test "real Exchange branch push triggers a new poll after initial reconciliation" do
    unless Process.whereis(Exchange), do: start_supervised!({Exchange, name: Exchange})
    server = launch(Persistence.empty(), subscribe: true)
    finish_poll(server, {:ok, result([])})
    assert Exchange.publish("system.main.branch.push", %{topic: "system.main.branch.push", sha: "red"}) >= 1
    finish_poll(server, {:ok, result([observation("red", 1)])})
    assert MainWatch.state(server).sha == "red"
    assert_received {:emitted, "system.main.ci.failed", %{sha: "red"}}
  end

  test "real alert publication reaches Exchange with failure evidence" do
    unless Process.whereis(Exchange), do: start_supervised!({Exchange, name: Exchange})
    :ok = Exchange.subscribe("system.main.ci.failed")
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    server = launch(Persistence.empty(), emit_fun: :real)
    persisted = finish_poll(server, {:ok, result([observation("real-alert", 1)])})
    assert_received {:event, %{topic: "system.main.ci.failed", sha: "real-alert", failing_tests: :unknown}}
    assert MainWatch.state(server).status == :red
    stop_supervised!(MainWatch)

    stale_outbox = %{
      persisted
      | pending: [
          {"system.main.ci.failed",
           %{sha: "real-alert", signature: "new", run_urls: ["run"], failing_checks: [%{name: "test", conclusion: "failure"}], failing_tests: :unknown, last_green_sha: nil, suspect_merges: []}}
        ]
    }

    server = launch(stale_outbox, emit_fun: :real)
    persisted = finish_poll(server, {:ok, result([observation("real-alert", 1)])})
    assert persisted.pending == []
    refute_received {:event, %{topic: "system.main.ci.failed"}}
  end

  test "inherited RPC retains ancestor evidence but rejects a rewritten branch and expired history" do
    clock = start_supervised!({Agent, fn -> 3 end})
    server = launch(Persistence.empty(), now_fun: fn -> Agent.get(clock, & &1) end)
    finish_poll(server, {:ok, result([observation("failed", 1)])})
    fixed = %{observation("fixed", 2) | checks: [%{name: "test", conclusion: "success"}]}
    GenServer.cast(server, :reconcile)
    finish_poll(server, {:ok, %{result([fixed]) | commits: ~w(fixed base failed)}})
    assert MainWatch.inherited?("test", "base", server) == :inherited
    Agent.update(clock, fn _ -> 8 * 24 * 60 * 60_000 end)
    assert MainWatch.inherited?("test", "base", server) == :unknown
    Agent.update(clock, fn _ -> 3 end)
    GenServer.cast(server, :reconcile)
    finish_poll(server, {:ok, %{result([]) | commits: ["rewritten"]}})
    assert MainWatch.inherited?("test", "base", server) == :unknown
  end

  test "idle green base stays quiet across canary windows" do
    clock = start_supervised!({Agent, fn -> 46 * 60_000 end})

    server =
      launch(%{Persistence.empty() | started_at: 0},
        config: %{workflows: [], canary_minutes: 45},
        now_fun: fn -> Agent.get(clock, & &1) end,
        suspects_fun: fn _, _, _, _, _ -> flunk("green CI must not fetch suspect associations") end
      )

    green = %{observation("green", 1) | checks: [%{name: "test", conclusion: "success"}]}
    poll = %{result([green]) | runs: [%{run("success", 1) | sha: "green"}]}
    finish_poll(server, {:ok, poll})
    assert MainWatch.state(server).status == :green
    refute_received {:emitted, _, _}
    Agent.update(clock, fn _ -> 92 * 60_000 end)
    GenServer.cast(server, :reconcile)
    finish_poll(server, {:ok, poll})
    refute_received {:emitted, _, _}
  end

  test "canary permission attention stays latched across windows and restart" do
    clock = start_supervised!({Agent, fn -> 46 * 60_000 end})
    opts = [config: %{workflows: [], canary_minutes: 45}, now_fun: fn -> Agent.get(clock, & &1) end]
    server = launch(%{Persistence.empty() | started_at: 0}, opts)
    poll = %{result([]) | commits: ["old"], runs: [run("cancelled", 0)]}
    data = finish_poll(server, {:ok, poll})
    assert_received {:emitted, "system.main.ci.canary", %{outcome: %{reason: ":actions_write_unavailable"}}}
    assert data.canary_permission_notified
    stop_supervised!(MainWatch)
    Agent.update(clock, fn _ -> 92 * 60_000 end)
    server = launch(data, opts)
    finish_poll(server, {:ok, poll})
    refute_received {:emitted, _, _}
  end

  test "a crashed poll retains green evidence and marks it unavailable" do
    server = launch(Persistence.empty())
    green = %{observation("green", 1) | checks: [%{name: "test", conclusion: "success"}]}
    finish_poll(server, {:ok, result([green])})
    GenServer.cast(server, :reconcile)
    receive_barrier({:poll_worker, worker})
    Process.exit(worker, :kill)
    receive_barrier({:saved, data})
    assert data.unavailable
    assert %{status: :green, sha: "green", completed_at: 1, unavailable: true} = MainWatch.state(server)
    assert_received {:emitted, "system.main.ci.unavailable", %{reason: reason}}
    assert reason =~ "poll_crashed"
  end

  test "webhook burst is debounced into one reconciliation" do
    server = launch(Persistence.empty(), debounce_ms: 20)
    finish_poll(server, {:ok, result([])})
    Enum.each(1..16, fn _ -> GenServer.cast(server, :reconcile) end)
    finish_poll(server, {:ok, result([])})
    Process.sleep(50)
    refute_received {:poll_worker, _}
  end

  test "one reconciliation never issues more than 64 transport requests" do
    requests = :atomics.new(1, [])
    green = %{observation("green", 1) | checks: [%{name: "test", conclusion: "success"}]}

    poll = fn _, _, opts ->
      Enum.reduce_while(1..65, {:ok, result([green])}, fn id, success ->
        case opts[:request_fun].(%{id: id}) do
          {:ok, _} -> {:cont, success}
          error -> {:halt, error}
        end
      end)
    end

    server =
      launch(Persistence.empty(),
        poll_fun: poll,
        request_fun: fn _ ->
          :atomics.add_get(requests, 1, 1)
          {:ok, %{status: 200}}
        end
      )

    receive_barrier({:saved, data})
    assert :atomics.get(requests, 1) == 64
    assert data.unavailable
    assert %{status: :unknown, unavailable: true} = MainWatch.state(server)
    assert_received {:emitted, "system.main.ci.unavailable", %{reason: ":main_watch_request_limit"}}
  end

  defp launch(initial, overrides \\ []) do
    parent = self()

    poll = fn _, _, _ ->
      send(parent, {:poll_worker, self()})

      receive do
        {:complete, result} -> result
      end
    end

    save = fn _, _, data ->
      send(parent, {:saved, data})
      :ok
    end

    emit = fn topic, payload ->
      send(parent, {:emitted, topic, payload})
      :ok
    end

    options = [
      name: nil,
      config: %{workflows: [], canary_minutes: 0},
      branch: "main",
      repo: "owner/repo",
      interval_ms: 60_000,
      debounce_ms: 0,
      subscribe: false,
      actions_write: false,
      load_fun: fn _, _ -> initial end,
      poll_fun: poll,
      save_fun: save,
      emit_fun: emit,
      now_fun: fn -> 0 end,
      suspects_fun: fn _, _, _, _, _ -> [] end
    ]

    options = Keyword.merge(options, overrides)
    options = if options[:emit_fun] == :real, do: Keyword.delete(options, :emit_fun), else: options
    start_supervised!({MainWatch, options})
  end

  defp finish_poll(server, result) do
    receive_barrier({:poll_worker, worker})
    send(worker, {:complete, result})
    receive_barrier({:saved, data})
    MainWatch.state(server)
    drain_saved(data)
  end

  defp drain_saved(data) do
    receive do
      {:saved, later} -> drain_saved(later)
    after
      0 -> data
    end
  end

  defp result(observations), do: %{observations: observations, commits: observations |> Enum.map(& &1.sha) |> Enum.reverse(), runs: [], actions_write: false}

  defp observation(sha, at) do
    %{sha: sha, completed_at: at, checks: [%{name: "test", conclusion: "failure"}], digest: %FailureDigest{signature: "new", tests: :unknown}, run_urls: ["run"]}
  end

  defp run(conclusion, at), do: %{id: 3, sha: "old", attempt: 1, status: "completed", conclusion: conclusion, completed_at: at, url: "run"}
end
