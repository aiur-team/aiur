defmodule Aiur.Experiments.WindowEventsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.{Experiments, ExperimentsCLI}
  alias Aiur.Experiments.{Paths, Spec, WindowEvents}

  setup do
    root = Path.join(System.tmp_dir!(), "window-events-#{System.unique_integer([:positive])}")
    old = Application.get_env(:aiur, :experiments_dir)
    Application.put_env(:aiur, :experiments_dir, root)

    on_exit(fn ->
      if old, do: Application.put_env(:aiur, :experiments_dir, old), else: Application.delete_env(:aiur, :experiments_dir)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    if !Process.whereis(Aiur.PubSub), do: start_supervised!({Phoenix.PubSub, name: Aiur.PubSub})
    start_supervised!(Aiur.Experiments.Store)
    fixture = Jason.decode!(File.read!(Path.join(__DIR__, "fixtures/valid_line.json")))["spec"]
    {:ok, spec} = Spec.new(Map.put(fixture, "confounder_sources", %{"base_branch" => "main", "required_workflows" => ["CI"]}))
    File.mkdir_p!(Paths.experiment(spec.id))
    File.write!(Paths.file(spec.id, "spec.json"), Jason.encode!(spec))
    %{spec: Spec.to_map(spec)}
  end

  defp opts(rows, pulls \\ []) do
    [records_fun: fn _ -> {rows, []} end, alert_files: [], now: ~U[2026-10-11 00:00:00Z], github_fun: fn _, _, _, _ -> {%{"pulls" => pulls}, []} end]
  end

  defp pull(number, at), do: %{"number" => number, "mergedAt" => at, "title" => "PR #{number}"}

  test "events are sorted, windowed and hashed independently of input order", %{spec: spec} do
    pulls = [pull(2, "2026-10-10T12:00:00Z"), pull(1, "2026-10-08T12:00:00Z"), pull(3, "2026-09-24T12:00:00Z"), pull(4, "2026-09-01T12:00:00Z")]
    first = WindowEvents.collect(spec, opts([], pulls))
    second = WindowEvents.collect(spec, opts([], Enum.reverse(pulls)))
    assert first["snapshot_hash"] == second["snapshot_hash"]
    assert Enum.map(first["events"], &{&1["ref"], &1["window"]}) == [{Paths.repo() <> "#3", "margin"}, {Paths.repo() <> "#1", "before"}, {Paths.repo() <> "#2", "after"}]
  end

  test "outage fixture is classified in the after window", %{spec: spec} do
    rows =
      for {boot, at} <- [{"a", "2026-10-09T01:00:00Z"}, {"b", "2026-10-09T04:00:00Z"}], do: %{"kind" => "restart", "boot_id" => boot, "timestamp" => at, "attributes" => %{"event" => "daemon_restart"}}

    assert [%{"kind" => "outage", "window" => "after", "from" => "2026-10-09T01:00:00Z", "to" => "2026-10-09T04:00:00Z"}] = WindowEvents.collect(spec, opts(rows))["events"]
  end

  test "freeze reuses local bytes while refresh preserves old IDs in a new file", %{spec: spec} do
    assert {:ok, first} = Experiments.events(spec["id"], opts([], [pull(1, "2026-10-10T00:00:00Z")]))
    bytes = File.read!(Paths.file(spec["id"], "events-1.ndjson"))
    assert {:ok, ^first} = Experiments.events(spec["id"], github_fun: fn _, _, _, _ -> flunk("cached read contacted GitHub") end)
    assert {:ok, refreshed} = Experiments.events(spec["id"], Keyword.put(opts([], [pull(1, "2026-10-10T00:00:00Z"), pull(2, "2026-10-10T01:00:00Z")]), :refresh, true))
    assert refreshed["snapshot"] == "events-2.ndjson"
    assert refreshed["snapshot_hash"] != first["snapshot_hash"]
    assert hd(refreshed["events"])["event_id"] == hd(first["events"])["event_id"]
    assert File.read!(Paths.file(spec["id"], "events-1.ndjson")) == bytes
    assert {:ok, ^refreshed} = WindowEvents.snapshot(spec)
  end

  test "GitHub failure freezes a partial ledger and CLI exits zero with stderr warning", %{spec: spec} do
    options = Keyword.put(opts([]), :github_fun, fn _, _, _, _ -> {%{}, ["github"]} end)
    assert {:ok, snapshot} = Experiments.events(spec["id"], options)
    assert "github" in snapshot["incomplete_sources"]
    parent = self()

    output =
      capture_io(fn ->
        warning = capture_io(:stderr, fn -> assert ExperimentsCLI.run(verb: :events, argv: [spec["id"], "--json"]) == 0 end)
        send(parent, {:warning, warning})
      end)

    assert_receive {:warning, warning}, 1_000
    assert warning =~ "warning: incomplete event sources:"
    assert warning =~ "github"
    assert Jason.decode!(output) == snapshot
  end

  test "critical alerts are included and noncritical alerts are excluded", %{spec: spec} do
    file = Paths.file(spec["id"], "alert-fixture.ndjson")
    alerts = for severity <- ["critical", "warning"], do: %{"event_id" => severity, "severity" => severity, "timestamp" => "2026-10-10T00:00:00Z", "message" => "Service down"}
    File.write!(file, Enum.map(alerts, &[Jason.encode!(&1), "\n"]))
    assert [%{"kind" => "incident", "source" => "alerts", "title" => "Service down", "window" => "after"}] = WindowEvents.collect(spec, Keyword.put(opts([]), :alert_files, [file]))["events"]
  end

  test "consumer source settings are validated by Elixir and the published schema", %{spec: spec} do
    schema = Path.expand("../../../priv/experiments/spec.v1.schema.json", __DIR__) |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    valid = Map.put(spec, "confounder_sources", %{"base_branch" => "trunk", "required_workflows" => ["CI"], "incident_labels" => ["incident"]})
    assert {:ok, _spec} = Spec.new(valid)
    assert ExJsonSchema.Validator.validate(schema, valid) == :ok

    for invalid <- [%{"unknown" => true}, %{"required_workflows" => [""]}, %{"base_branch" => ""}] do
      assert {:error, errors} = Spec.new(Map.put(spec, "confounder_sources", invalid))
      assert Enum.any?(errors, &String.starts_with?(&1.path, "confounder_sources"))
      refute ExJsonSchema.Validator.validate(schema, Map.put(spec, "confounder_sources", invalid)) == :ok
    end
  end

  test "concurrent first requests share one frozen snapshot", %{spec: spec} do
    tasks = for _ <- 1..2, do: Task.async(fn -> Experiments.events(spec["id"], opts([], [pull(1, "2026-10-10T00:00:00Z")])) end)
    [first, second] = Enum.map(tasks, &Task.await/1)
    assert first == second
    assert {:ok, %{"snapshot" => "events-1.ndjson"}} = first
    assert Path.wildcard(Paths.file(spec["id"], "events-*.ndjson")) == [Paths.file(spec["id"], "events-1.ndjson")]
  end

  test "tampering with frozen evidence fails its hash check", %{spec: spec} do
    assert {:ok, _first} = Experiments.events(spec["id"], opts([], [pull(1, "2026-10-10T00:00:00Z")]))
    file = Paths.file(spec["id"], "events-1.ndjson")
    File.write!(file, String.replace(File.read!(file), "PR 1", "PR tampered"))
    assert {:error, :invalid_events_snapshot} = Experiments.events(spec["id"])
  end
end
