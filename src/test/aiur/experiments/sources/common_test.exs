defmodule Aiur.Experiments.Sources.CommonTest do
  use ExUnit.Case, async: true
  alias Aiur.Experiments.{Evaluator, Metric}
  alias Aiur.Experiments.Sources.Common
  @window %{start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-02-01 00:00:00Z]}

  setup do
    root = Path.join(System.tmp_dir!(), "capture-common-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "only overlapping months affect capture; corruption and torn tails fail closed", %{root: root} do
    january = Path.join(root, "events-2026-01.ndjson")
    File.write!(january, Jason.encode!(%{metric_ref: "app/requests", topic: "executor.app.request", at: "2026-01-01T12:00:00Z", unit: "request-1", attrs: %{}}) <> "\n")
    File.write!(Path.join(root, "events-2026-02.ndjson"), "{\"metric_ref\":")
    ctx = %{capture_root: root, capture_server: nil}
    assert {:ok, [%{"unit" => "request-1"}]} = Common.events("app/requests", @window, ctx)
    assert {:error, :capture_corrupt} = Common.events("app/requests", %{start: @window.end, end: ~U[2026-03-01 00:00:00Z]}, ctx)
    assert {:error, :capture_corrupt} = Common.events("app/requests", %{start: @window.start, end: ~U[2026-02-01 00:00:00.000001Z]}, ctx)
    File.write!(january, File.read!(january) <> "{\"metric_ref\":")
    assert {:error, :capture_corrupt} = Common.events("app/requests", @window, ctx)
  end

  test "evaluation shares month, error, coverage and live status reads across event metrics", %{root: root} do
    refs = ["app/requests", "app/other"]
    catalog = %{packs: %{}, metrics: Map.new(refs, &{&1, %Metric{id: &1, pack: "app", source: %{"kind" => "event_count", "match" => "executor.app.#"}}})}
    File.write!(Path.join(root, "events-2026-01.ndjson"), "")
    File.write!(Path.join(root, "events-2026-02.ndjson"), "broken")
    File.write!(Path.join(root, "coverage.json"), Jason.encode!(Map.new(refs, &{&1, DateTime.to_iso8601(@window.start)})))
    File.write!(Path.join(root, "errors.json"), "{}")

    ctx = %{
      catalog: catalog,
      capture_root: root,
      capture_server: self(),
      capture_status: fn _server ->
        send(self(), :status_read)
        %{errors: %{}}
      end,
      capture_read: fn path ->
        send(self(), {:file_read, Path.basename(path)})
        File.read(path)
      end
    }

    results = Evaluator.observations(refs, @window, ctx)
    for ref <- refs, do: assert(%{coverage: %{state: :captured}, observations: []} = results[ref])
    assert_receive :status_read, 1_000
    refute_receive :status_read, 20

    for file <- ["events-2026-01.ndjson", "coverage.json", "errors.json"] do
      assert_receive {:file_read, ^file}, 1_000
      refute_receive {:file_read, ^file}, 20
    end

    refute_receive {:file_read, "events-2026-02.ndjson"}, 20
  end

  test "future regression guard: unknown and non-event refs do not prepare capture", %{root: root} do
    metric = %Metric{id: "samples", pack: "app", source: %{"kind" => "ndjson", "path" => "samples.ndjson"}}
    File.write!(Path.join(root, "samples.ndjson"), "")
    script = %Metric{id: "script", pack: "app", source: %{"kind" => "script", "argv" => ["/bin/true"]}}

    ctx = %{
      catalog: %{packs: %{}, metrics: %{"app/samples" => metric, "app/script" => script}},
      repo_path: root,
      capture_server: self(),
      capture_status: fn _server -> flunk("non-event evaluation read capture status") end,
      capture_read: fn _path -> flunk("non-event evaluation read capture files") end
    }

    assert %{coverage: %{state: :unavailable, reason: :metric_missing}} = Evaluator.observations(["gone/value"], @window, ctx)["gone/value"]
    assert %{observations: []} = Evaluator.observations(["app/samples"], @window, ctx)["app/samples"]
    assert %{observations: []} = Evaluator.observations(["app/script"], @window, ctx)["app/script"]
  end

  test "future regression guard: prepared evaluation preserves injected events and coverage", %{root: root} do
    ref = "app/requests"
    metric = %Metric{id: "requests", pack: "app", source: %{"kind" => "event_count", "match" => "executor.app.#"}}

    ctx = %{
      catalog: %{packs: %{}, metrics: %{ref => metric}},
      capture_root: root,
      capture_server: nil,
      events: [%{"metric_ref" => ref, "topic" => "executor.app.request", "at" => @window.start, "unit" => "request-1"}],
      capture_started_at: @window.start
    }

    assert %{coverage: %{state: :captured}, observations: [%{unit_id: "request-1", value: 1}]} = Evaluator.observations([ref], @window, ctx)[ref]
  end
end
