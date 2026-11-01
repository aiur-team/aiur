defmodule AiurWeb.BuildLiveReadTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  alias Aiur.TestSupport.LiveViewAsync
  import ExUnit.CaptureLog

  alias Aiur.TestSupport.EndpointStubs

  for {mode, reason} <- [raise: "read_failed", exit: "read_failed", error: "read_failed"] do
    test "resync safely rejects #{mode} source and remains alive" do
      source(mode: unquote(mode))
      {:ok, view, _} = live(build_conn(), "/build")
      LiveViewAsync.render_when_complete(view)
      render_hook(view, "build-resync", %{})
      assert_reply(view, %{"kind" => "error", "reason" => unquote(reason)})
      assert Process.alive?(view.pid)
    end
  end

  @tag timeout: 15_000
  test "held source is bounded to five seconds and view survives" do
    source(mode: :hold)
    {:ok, view, _} = live(build_conn(), "/build")
    start = System.monotonic_time(:millisecond)
    render_hook(view, "build-resync", %{})
    assert_reply(view, %{"kind" => "error", "reason" => "timeout"})
    assert System.monotonic_time(:millisecond) - start < 6_000
    assert Process.alive?(view.pid)
  end

  test "resync serves a snapshot that holds an agent in retry backoff" do
    source(mode: :retrying)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, %{"kind" => "snapshot"} = reply)
    assert hd(reply["sections"]["now"])["agent"]["state"] == "retrying"
  end

  test "resync preserves the index timeout cause" do
    source(mode: :error, error_reason: :timeout)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, %{"kind" => "error", "reason" => "timeout"})
    assert Process.alive?(view.pid)
  end

  test "resync floods are throttled to one read per interval" do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    flush_reads()
    {:ok, clock} = Agent.start_link(fn -> 10_000 end)
    EndpointStubs.put(build_resync_clock: fn _ -> Agent.get(clock, & &1) end)
    ref = make_ref()
    pid = self()
    :telemetry.attach(ref, [:aiur, :build, :resync_throttled], fn _, m, _, _ -> send(pid, {:throttled, m.count}) end, nil)
    on_exit(fn -> :telemetry.detach(ref) end)

    for _ <- 1..100, do: render_hook(view, "build-resync", %{})
    assert length(flush_reads()) == 1
    # first resync is served from the mount-time cache, second reads
    assert length(flush_throttled()) == 98
    assert_reply(view, %{"kind" => "error", "reason" => "throttled"})

    Agent.update(clock, &(&1 + 2_001))
    render_hook(view, "build-resync", %{})
    assert length(flush_reads()) == 1
    assert flush_throttled() == []
  end

  defp flush_reads(acc \\ []), do: receive(do: ({:read, _} = m -> flush_reads([m | acc])), after: (0 -> acc))
  defp flush_throttled(acc \\ []), do: receive(do: ({:throttled, _} = m -> flush_throttled([m | acc])), after: (0 -> acc))

  test "part failures preserve unavailable cause inside a valid snapshot" do
    source(part_failure: true)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, reply)
    assert reply["sources"]["queue"] == %{"state" => "unavailable", "observed_at" => nil, "reason" => "queue_down"}
    assert reply["sections"]["plan"] == []
  end

  test "one invalid planned row is dropped while the rest of the snapshot remains available" do
    source(mode: :invalid)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    log = capture_log(fn -> render_hook(view, "build-resync", %{}) end)
    assert_reply(view, %{"kind" => "snapshot"} = snapshot)
    assert length(snapshot["sections"]["plan"]) == length(data()["sections"]["plan"]) - 1
    assert snapshot["unavailable_rows"] == 1
    assert log =~ "path=sections.plan.0"
    assert log =~ "wave"
  end

  test "a dropped row recovery restarts the client snapshot to restore cross-row references" do
    source(mode: :invalid)
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    render_hook(view, "build-resync", %{})
    assert_reply(view, %{"kind" => "snapshot", "unavailable_rows" => 1})

    recovered = hd(data()["sections"]["plan"])
    send(view.pid, {:build_changes, change(recovered)})
    render(view)

    assert_push_event(view, "build-diff", %{"generation" => 2, "upsert" => [], "remove" => [], "set" => %{}})
    assert Process.alive?(view.pid)
  end

  test "malformed changes request a resync without killing the view" do
    {:ok, view, _} = live(build_conn(), "/build")
    LiveViewAsync.render_when_complete(view)
    row = hd(data()["sections"]["now"])

    for {changes, generation} <- [{:bad, 2}, {%{change(row) | set: %{history_meta: "bad"}}, 4}] do
      send(view.pid, {:build_changes, changes})
      render(view)
      assert_push_event(view, "build-diff", %{"generation" => ^generation, "upsert" => [], "remove" => [], "set" => %{}})
      assert Process.alive?(view.pid)
    end
  end
end
