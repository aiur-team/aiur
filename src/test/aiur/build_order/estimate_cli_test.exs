defmodule Aiur.BuildOrder.EstimateCLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Aiur.BuildOrder.{EstimateCLI, Estimates}

  setup do
    dir = Aiur.TestSupport.tmp_root!("estimate-cli")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    server = start_supervised!({Estimates, name: nil, state_dir: dir, repository: "owner/repo"})
    snapshot = fn -> {:ok, %{sections: %{plan: [%{num: 5, cx: 2}]}, sources: %{queue: %{state: "ok"}}}} end
    %{opts: [id: 5, server: server, snapshot_fun: snapshot], dir: dir}
  end

  test "RPC prints human default, override and journal and JSON record", %{opts: opts} do
    output = capture_io(fn -> assert :ok = Aiur.AgentControlCLI.ticket_estimate(opts ++ [hours: "7", reason: "rounds", by: "cli:kevin"]) end)
    assert output =~ "#5 estimate ≈7h (override by cli:kevin,"
    assert output =~ "default ≈2h from complexity:2"
    assert output =~ "Reason: rounds"
    assert output =~ "Journal:\n  set ≈7h by cli:kevin"
    assert output =~ "__AIUR_CONTROL_EXIT__:0"
    json = capture_io(fn -> assert EstimateCLI.run(opts ++ [json: true]) == 0 end) |> Jason.decode!()
    assert json["default_hours"] == 2
    assert json["planned"] == true
    assert json["override"]["hours"] == 7
    assert json["override"]["reason"] == "rounds"
    assert length(json["journal"]) == 1
    clear = capture_io(fn -> assert EstimateCLI.run(opts ++ [clear: true, reason: "done"]) == 0 end)
    assert clear =~ "no override"
    assert clear =~ "clear —"
  end

  test "unknown and absent plans are reported honestly; hours keep integral zeroes", %{opts: opts} do
    missing = Keyword.put(opts, :id, 8)
    output = capture_io(fn -> assert EstimateCLI.run(missing ++ [hours: "100", reason: "large"]) == 0 end)
    assert output =~ "≈100h"
    assert output =~ "not planned now; no card shows it until it is queued"
    unknown = Keyword.put(opts, :snapshot_fun, fn -> {:error, :unavailable} end)
    json = capture_io(fn -> assert EstimateCLI.run(unknown ++ [json: true]) == 0 end) |> Jason.decode!()
    assert json["planned"] == "unknown"
    assert json["default_hours"] == nil
  end

  test "queue health governs absence while other sections supply complexity", %{opts: opts} do
    for {state, expected} <- [{"disabled", false}, {"stale", "unknown"}, {"incomplete", "unknown"}, {"unavailable", "unknown"}, {"ok", false}] do
      snapshot = fn -> {:ok, %{sections: %{plan: [], now: [%{num: 5, cx: 4}]}, sources: %{queue: %{state: state}}}} end
      args = Keyword.put(opts, :snapshot_fun, snapshot) ++ [json: true]
      json = capture_io(fn -> assert EstimateCLI.run(args) == 0 end) |> Jason.decode!()
      assert json["planned"] == expected
      assert json["default_hours"] == 7
    end

    for state <- ["stale", "incomplete"] do
      snapshot = fn -> {:ok, %{sections: %{plan: [%{num: 5, cx: nil}]}, sources: %{queue: %{state: state}}}} end
      json = capture_io(fn -> assert EstimateCLI.run(Keyword.put(opts, :snapshot_fun, snapshot) ++ [json: true]) == 0 end) |> Jason.decode!()
      assert json["planned"] == true
      assert json["default_hours"] == nil
    end
  end

  test "daemon entry rejects invalid input without writing", %{opts: opts} do
    for change <- [
          [hours: "2.3", reason: "x"],
          [hours: 0, reason: "x"],
          [hours: 7, reason: "\nx"],
          [hours: 7, reason: " "],
          [hours: 7, reason: "x", by: "bad actor"],
          [clear: true, hours: 1, reason: "x"]
        ] do
      capture_io(fn -> assert EstimateCLI.run(opts ++ change ++ [error_fun: &IO.puts/1]) == 1 end)
    end

    assert {:ok, %{override: nil, journal: []}} = Estimates.get(5, server: opts[:server])
  end

  test "unavailable store prints error marker, recovery advice and exit one", %{opts: opts, dir: dir} do
    corrupt = Path.join(dir, "corrupt")
    File.mkdir_p!(corrupt)
    File.write!(Path.join(corrupt, "estimates.json"), "{not json")
    server = start_supervised!(Supervisor.child_spec({Estimates, name: nil, state_dir: corrupt, repository: "owner/repo"}, id: :corrupt_estimates))
    unavailable = Keyword.put(opts, :server, server)
    output = capture_io(fn -> capture_io(:stderr, fn -> Aiur.AgentControlCLI.ticket_estimate(unavailable) end) end)
    assert output =~ "__AIUR_CONTROL_ERROR__:"
    assert output =~ "estimate store unavailable (estimates_corrupt)"
    assert output =~ ".corrupt-*, then restart"
    assert output =~ "__AIUR_CONTROL_EXIT__:1"
  end
end
