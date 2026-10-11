defmodule Aiur.Experiments.CaptureTest do
  use ExUnit.Case, async: true
  alias Aiur.Events.Exchange
  alias Aiur.Experiments.Capture

  setup do
    root = Path.join(System.tmp_dir!(), "capture-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    packs = Path.join(repo, ".aiur/experiments/packs")
    File.mkdir_p!(packs)
    on_exit(fn -> File.rm_rf!(root) end)
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
