defmodule Aiur.ListenModeCliTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{ListenModeCli, Listener, Orchestrator}
  alias Aiur.Orchestrator.{ListenerModes, State}

  defmodule Server do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Aiur.Orchestrator)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:listener_get_mode, id}, _from, state), do: ListenerModes.get_mode(state, id)
    def handle_call({:listener_set_mode, id, mode, opts}, _from, state), do: ListenerModes.set_mode(state, id, mode, opts)
  end

  setup do
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Orchestrator) end)
    dir = Aiur.TestSupport.tmp_root!("listen-mode-cli")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    start_supervised!({Server, %State{last_polled_issues: %{"42" => %{identifier: "42"}}}})
    :ok
  end

  test "set prints requested and unavailable effective mode with reason and stores actor" do
    output = capture_io(fn -> ListenModeCli.run("42", ["async", "--actor", "executor"]) end)
    assert output =~ "requested async; effective unknown; reason not_running; version 1; actor executor"
    assert output =~ "legacy routing ignores the stored mode"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    assert {:ok, %{requested: :async, version: 1, actor: :executor}} = Listener.get_mode("42")
  end

  test "JSON reads include actual mode and observation freshness" do
    {:ok, _} = Listener.set_mode("42", :steer, expected_version: 0)
    output = capture_io(fn -> ListenModeCli.run("42", ["--json"]) end)
    record = output |> String.split("\n") |> hd() |> Jason.decode!()
    assert record["requested"] == "steer"
    assert record["effective"] == nil
    assert record["effective_reason"] == "not_running"
    assert record["version"] == 1
    assert record["age_ms"] == 0
    assert record["freshness"] == "fresh"
    assert {:ok, observed, 0} = DateTime.from_iso8601(record["observed_at"])
    assert abs(DateTime.diff(DateTime.utc_now(), observed)) < 5
  end

  test "stale explicit version exits 3 and prints current record without overwriting it" do
    {:ok, _} = Listener.set_mode("42", :steer, expected_version: 0)
    output = capture_io(fn -> ListenModeCli.run("42", ["async", "--expected-version", "0"]) end)
    assert output =~ "mode_conflict"
    assert output =~ "requested steer"
    assert output =~ "__AIUR_CONTROL_EXIT__:3"
    assert {:ok, %{requested: :steer, version: 1}} = Listener.get_mode("42")
  end

  test "invalid mode, actor, version and unknown tickets cannot write" do
    for argv <- [["bogus"], ["sync", "--actor", "system"], ["sync", "--expected-version", "-1"], ["sync", "--bad"]] do
      assert capture_io(fn -> ListenModeCli.run("42", argv) end) =~ "__AIUR_CONTROL_EXIT__:1"
    end

    assert {:ok, %{version: 0}} = Listener.get_mode("42")
    assert capture_io(fn -> ListenModeCli.run("unknown", []) end) =~ "issue_not_found"
  end
end
