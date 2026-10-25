defmodule Aiur.Experiments.CaptureTest do
  # Lifecycle cases share one capture/Exchange fixture so outage and recovery exercise the same journal.
  use ExUnit.Case, async: true
  alias Aiur.Events.Exchange
  alias Aiur.Experiments.{Capture, Evaluator}

  setup do
    root = Path.join(System.tmp_dir!(), "capture-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    packs = Path.join(repo, ".aiur/experiments/packs")
    File.mkdir_p!(packs)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    {:ok, exchange} = start_supervised({Exchange, []})
    {:ok, clock} = start_supervised({Agent, fn -> ~U[2026-10-01 00:00:00Z] end})
    context = %{repo_path: repo, builtin_packs: []}
    %{root: root, packs: packs, context: context, exchange: exchange, clock: clock}
  end

  test "journals only declared scalar fields and deduplicates overlapping bindings", ctx do
    pack(ctx.packs, %{"kind" => "event_interval", "start" => "app.deploy.*", "end" => "app.#", "unit_key" => "/deployment/id", "attrs" => %{"region" => "/region"}})
    pid = capture(ctx)
    assert Enum.sort(Exchange.bindings_for(pid, ctx.exchange)) == ["app.#", "app.deploy.*"]
    event = %{id: 1, topic: "app.deploy.started", deployment: %{id: "d1"}, region: "west", body: "secret comment"}
    assert Exchange.publish(event.topic, event, ctx.exchange) == 2
    assert Capture.status(pid).dropped == 0
    [row] = rows(ctx, "2026-10")
    assert row == %{"metric_ref" => "app/latency", "topic" => "app.deploy.started", "at" => "2026-10-01T00:00:00Z", "unit" => "d1", "attrs" => %{"region" => "west"}}
    refute File.read!(Path.join(ctx.root, "capture/events-2026-10.ndjson")) =~ "secret comment"
  end

  test "scalar deployment identifiers are journaled as observation unit strings", ctx do
    pack(ctx.packs, source())
    pid = capture(ctx)
    Exchange.publish("app.deploy.started", %{id: 101, topic: "app.deploy.started", id_value: 42}, ctx.exchange)
    assert Capture.status(pid).dropped == 0
    assert [%{"unit" => "42"}] = rows(ctx, "2026-10")
  end

  test "reload unsubscribes removed metrics and resets coverage when registered again", ctx do
    pack(ctx.packs, source())
    pid = capture(ctx)
    initial = Capture.status(pid).coverage["app/latency"]
    File.rm!(Path.join(ctx.packs, "app.json"))
    assert :ok = Capture.refresh(pid)
    assert Exchange.bindings_for(pid, ctx.exchange) == []
    assert Exchange.publish("app.deploy.started", %{topic: "app.deploy.started"}, ctx.exchange) == 0
    Agent.update(ctx.clock, fn _ -> ~U[2026-10-02 00:00:00Z] end)
    pack(ctx.packs, source())
    assert :ok = Capture.refresh(pid)
    assert Capture.status(pid).coverage["app/latency"] == "2026-10-02T00:00:00Z"
    refute Capture.status(pid).coverage["app/latency"] == initial
  end

  test "write failure is fail-open, counted, and persisted as unavailable evidence", ctx do
    pack(ctx.packs, source())
    pid = capture(ctx, append: fn _path, _row -> {:error, :enospc} end)
    Exchange.publish("app.deploy.started", %{id: 3, topic: "app.deploy.started", id_value: "a"}, ctx.exchange)
    assert %{dropped: 1, errors: %{"app/latency" => ":enospc"}} = Capture.status(pid)
    assert Process.alive?(pid)
    assert Jason.decode!(File.read!(Path.join(ctx.root, "capture/errors.json"))) == %{"app/latency" => ":enospc"}
  end

  test "restart cannot claim coverage across daemon downtime", ctx do
    pack(ctx.packs, source())
    pid = capture(ctx)
    assert Capture.status(pid).coverage["app/latency"] == "2026-10-01T00:00:00Z"
    stop_supervised(Capture)
    Agent.update(ctx.clock, fn _ -> ~U[2026-10-03 00:00:00Z] end)
    restarted = capture(ctx)
    assert Capture.status(restarted).coverage["app/latency"] == "2026-10-03T00:00:00Z"
  end

  test "month rollover and retention preserve the oldest active experiment window", ctx do
    pack(ctx.packs, source())
    root = Path.join(ctx.root, "capture")
    File.mkdir_p!(root)
    for month <- ["2024-01", "2024-06", "2025-11"], do: File.write!(Path.join(root, "events-#{month}.ndjson"), "")
    experiment = Path.join(ctx.root, "active-experiment")
    File.mkdir_p!(experiment)
    File.write!(Path.join(experiment, "spec.json"), Jason.encode!(%{status: "active", windows: %{before: %{start: "2024-06-02T00:00:00Z"}}}))
    pid = capture(ctx)
    refute File.exists?(Path.join(root, "events-2024-01.ndjson"))
    assert File.exists?(Path.join(root, "events-2024-06.ndjson"))
    assert File.exists?(Path.join(root, "events-2025-11.ndjson"))
    Exchange.publish("app.deploy.started", %{id: 4, topic: "app.deploy.started"}, ctx.exchange)
    Capture.status(pid)
    assert length(rows(ctx, "2026-10")) == 1
    Agent.update(ctx.clock, fn _ -> ~U[2026-11-01 00:00:00Z] end)
    Exchange.publish("app.deploy.started", %{id: 5, topic: "app.deploy.started"}, ctx.exchange)
    Capture.status(pid)
    assert length(rows(ctx, "2026-11")) == 1
    File.write!(Path.join(root, "events-2024-01.ndjson"), "")
    File.write!(Path.join(experiment, "spec.json"), Jason.encode!(%{status: "active", windows: %{before: %{start: "invalid"}}}))
    Capture.refresh(pid)
    assert File.exists?(Path.join(root, "events-2024-01.ndjson"))
  end

  test "invalid pack alerts once per changed file content", ctx do
    path = Path.join(ctx.packs, "invalid.json")
    File.write!(path, "not json")
    owner = self()
    pid = capture(ctx, alert: fn message -> send(owner, {:pack_alert, message}) end)
    assert_receive {:pack_alert, message}, 1000
    assert message =~ "invalid.json"
    assert :ok = Capture.refresh(pid)
    refute_receive {:pack_alert, _message}, 20
    File.write!(path, "still not json")
    assert :ok = Capture.refresh(pid)
    assert_receive {:pack_alert, changed_message}, 1000
    assert changed_message =~ "invalid.json"
  end

  test "flood bounds journal work and makes observations unavailable", ctx do
    pack(ctx.packs, Map.put(source(), "match", "#"))
    counts = start_supervised!({Agent, fn -> %{appends: 0, errors: 0, coverage: 0} end}, id: :counts)

    append = fn path, row ->
      Agent.update(counts, &Map.update!(&1, :appends, fn n -> n + 1 end))
      Aiur.Journal.append(path, row)
    end

    pid = capture(ctx, append: append, write: counted_writer(counts), queue_limit: 8)
    assert :ok = :sys.suspend(pid)
    for id <- 1..100, do: Exchange.publish("app.deploy.started", %{id: id, topic: "app.deploy.started", id_value: "d#{id}"}, ctx.exchange)
    assert :ok = :sys.resume(pid)
    assert %{dropped: 100, errors: %{"app/latency" => ":capture_overloaded"}} = Capture.status(pid)
    assert Agent.get(counts, & &1) == %{appends: 0, errors: 2, coverage: 1}
    assert :ok = Capture.refresh(pid)
    assert Agent.get(counts, & &1) == %{appends: 0, errors: 2, coverage: 1}
    window = %{start: ~U[2026-10-01 00:00:00Z], end: ~U[2026-10-02 00:00:00Z]}
    context = Map.merge(ctx.context, %{capture_root: Path.join(ctx.root, "capture"), capture_server: pid})
    assert %{coverage: %{state: :unavailable, reason: ":capture_overloaded"}, observations: []} = Evaluator.observations(["app/latency"], window, context)["app/latency"]
  end

  test "failed appends and unchanged refresh do not repeat persistence", ctx do
    pack(ctx.packs, source())
    counts = start_supervised!({Agent, fn -> %{appends: 0, errors: 0, coverage: 0} end}, id: :counts)

    append = fn _path, _row ->
      Agent.update(counts, &Map.update!(&1, :appends, fn n -> n + 1 end))
      {:error, :enospc}
    end

    pid = capture(ctx, append: append, write: counted_writer(counts))
    for id <- 1..20, do: Exchange.publish("app.deploy.started", %{id: id, topic: "app.deploy.started"}, ctx.exchange)
    assert Capture.status(pid).dropped == 20
    assert :ok = Capture.refresh(pid)
    assert Agent.get(counts, & &1) == %{appends: 1, errors: 2, coverage: 1}
  end

  test "metadata write failure is attempted once per state while events keep arriving", ctx do
    pack(ctx.packs, source())
    counts = start_supervised!({Agent, fn -> %{appends: 0, errors: 0, coverage: 0} end}, id: :counts)

    write = fn path, _body, _opts ->
      key = if Path.basename(path) == "errors.json", do: :errors, else: :coverage
      Agent.update(counts, &Map.update!(&1, key, fn n -> n + 1 end))
      {:error, :enospc}
    end

    append = fn _path, _row ->
      Agent.update(counts, &Map.update!(&1, :appends, fn n -> n + 1 end))
      :ok
    end

    pid = capture(ctx, append: append, write: write, queue_limit: 8)
    assert :ok = :sys.suspend(pid)
    for id <- 1..100, do: Exchange.publish("app.deploy.started", %{id: id, topic: "app.deploy.started"}, ctx.exchange)
    assert :ok = :sys.resume(pid)
    assert Capture.status(pid).errors == %{"app/latency" => ":enospc"}
    assert :ok = Capture.refresh(pid)
    assert Agent.get(counts, & &1) == %{appends: 0, errors: 1, coverage: 1}
  end

  test "Exchange outage clears coverage and rebinds after restart", ctx do
    pack(ctx.packs, source())
    name = Module.concat(__MODULE__, "Exchange#{System.unique_integer([:positive])}")
    exchange = start_supervised!({Exchange, name: name}, id: :restart_exchange)
    pid = capture(%{ctx | exchange: name})
    assert Exchange.bindings_for(pid, name) == ["app.deploy.started"]
    assert :ok = :sys.suspend(pid)
    assert :ok = stop_supervised(:restart_exchange)
    ref = Process.monitor(exchange)
    assert_receive {:DOWN, ^ref, :process, ^exchange, _reason}, 1000
    assert :ok = :sys.resume(pid)
    assert %{coverage: coverage, errors: %{"app/latency" => ":exchange_unavailable"}} = Capture.status(pid)
    assert coverage == %{}
    Agent.update(ctx.clock, fn _ -> ~U[2026-10-03 00:00:00Z] end)
    start_supervised!({Exchange, name: name}, id: :restart_exchange)
    assert :ok = Capture.refresh(pid)
    assert Capture.status(pid).coverage["app/latency"] == "2026-10-03T00:00:00Z"
    assert Capture.status(pid).errors == %{}
    assert Exchange.bindings_for(pid, name) == ["app.deploy.started"]
    Exchange.publish("app.deploy.started", %{id: 201, topic: "app.deploy.started", id_value: "recovered"}, name)
    assert Capture.status(pid).dropped == 0
    assert [%{"unit" => "recovered"}] = rows(ctx, "2026-10")
  end

  defp counted_writer(counts) do
    fn path, body, opts ->
      key = if Path.basename(path) == "errors.json", do: :errors, else: :coverage
      Agent.update(counts, &Map.update!(&1, key, fn n -> n + 1 end))
      Aiur.Fs.atomic_write(path, body, opts)
    end
  end

  defp capture(ctx, opts \\ []) do
    start_supervised!(
      {Capture,
       Keyword.merge([name: nil, alert: fn _message -> :ok end, context: ctx.context, root: Path.join(ctx.root, "capture"), exchange: ctx.exchange, clock: fn -> Agent.get(ctx.clock, & &1) end], opts)}
    )
  end

  defp rows(ctx, month), do: Path.join(ctx.root, "capture/events-#{month}.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp source, do: %{"kind" => "event_count", "match" => "app.deploy.started", "unit_key" => "/id_value"}

  defp pack(path, source) do
    metric = %{
      "id" => "latency",
      "label" => "Latency",
      "unit" => "ms",
      "unit_of_analysis" => "deploy",
      "kind" => "duration",
      "better" => "lower",
      "default_direction" => "decrease",
      "group" => "App",
      "requires" => [],
      "source" => source
    }

    File.write!(Path.join(path, "app.json"), Jason.encode!(%{schema_version: 1, id: "app", version: "1", metrics: [metric]}))
  end
end
