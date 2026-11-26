defmodule Aiur.GitHub.Listeners.FirehoseTest do
  use Aiur.TestSupport

  # Cursor and window cases share one poll fixture so latch transitions stay together.

  alias Aiur.AlertLedger
  alias Aiur.Events.Exchange
  alias Aiur.GitHub.Listeners
  alias Aiur.GitHub.Listeners.Firehose
  alias Aiur.Workflow

  setup do
    prev_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "aiur"
    )

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", prev_token)

      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    if is_nil(Process.whereis(Listeners)), do: start_supervised!(Listeners)
    Listeners.reset()
    :ok
  end

  test "listener preserves the GitHub firehose event watermark" do
    page_1 = ignored_events("burst", 30)
    page_2 = [ignored_event("last-seen")]
    parent = self()

    stub = fn req ->
      page = request_page(req)
      send(parent, {:events_page_requested, page})

      body =
        case page do
          "1" -> page_1
          "2" -> page_2
        end

      {:ok, %{status: 200, headers: [{"ETag", ~s("next-etag")}], body: body}}
    end

    state = %Firehose{
      events_etag: ~s("previous-etag"),
      events_last_id: "last-seen"
    }

    next = poll_firehose(state, request_fun: stub)

    assert next.events_etag == ~s("next-etag")
    assert next.events_last_id == "burst-1"
    assert_received {:events_page_requested, "1"}
    assert_received {:events_page_requested, "2"}
  end

  test "firehose reports pages fetched and cap status per tick" do
    parent = self()

    telemetry_fun = fn kind, attrs ->
      send(parent, {:firehose_metric, kind, attrs})
      :ok
    end

    stub = fn req ->
      page = request_page(req)
      body = if page == "1", do: Enum.take(ignored_events("m", 30), 5), else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("metric-etag")}], body: body}}
    end

    state =
      poll_firehose(%Firehose{},
        request_fun: stub,
        firehose_poll_telemetry_fun: telemetry_fun
      )

    assert_received {:firehose_metric, :firehose_poll, %{pages_fetched: 1, partial_window?: false, published: 0}}

    assert state.firehose_partial_streak == 0
    assert state.firehose_truncation_alert_active == false
  end

  # #2354: the cheapest tick is the If-None-Match 304, and the metric must not
  # zero it out. One actual HTTP read happened, so the window is reported as
  # page 1 of a complete (empty) window — not 0 pages — or the steady-state
  # cost of the poller would be invisible to the very metric #2354 asked for.
  test "a 304 tick reports one page read and a complete window" do
    parent = self()

    telemetry_fun = fn kind, attrs ->
      send(parent, {:firehose_metric, kind, attrs})
      :ok
    end

    stub = fn %{etag: ~s("e")} ->
      {:ok, %{status: 304, headers: [{"ETag", ~s("e")}], body: ""}}
    end

    state =
      poll_firehose(%Firehose{events_etag: ~s("e")},
        request_fun: stub,
        firehose_poll_telemetry_fun: telemetry_fun
      )

    assert_received {:firehose_metric, :firehose_poll, %{pages_fetched: 1, partial_window?: false, published: 0}}

    assert state.firehose_partial_streak == 0
    assert state.firehose_truncation_alert_active == false
  end

  # #2354 attention: a window that truncates once can be a boot reconciliation
  # or a burst, but a truncating window that keeps truncating is the steady
  # state the old 5-page cap hit on every tick — and that must raise attention
  # rather than pass silently. The attention fires once at the threshold, stays
  # armed on further truncation, and resolves the first tick the window is
  # complete again.
  test "firehose truncation attention fires on a sustained partial window and resolves on a complete one" do
    parent = self()
    counter = :counters.new(1, [:atomics])

    # Every page is saturated with fresh ids so the previous tick's watermark
    # is never reachable — the truncation that used to happen every tick.
    truncated = fn _req ->
      id = :counters.get(counter, 1) + 1
      :counters.add(counter, 1, 1)
      body = Enum.map(1..30, fn n -> ignored_event("gen-#{id}-#{n}") end)
      {:ok, %{status: 200, headers: [{"ETag", ~s("partial-etag")}], body: body}}
    end

    alert_fun = fn topic, opts ->
      send(parent, {:firehose_alert, topic, opts[:needs_attention]})
      :ok
    end

    state =
      Enum.reduce(1..2, %Firehose{}, fn _i, acc ->
        poll_firehose(acc,
          request_fun: truncated,
          firehose_truncation_alert_fun: alert_fun
        )
      end)

    assert state.firehose_partial_streak == 2
    assert state.firehose_truncation_alert_active
    assert_received {:firehose_alert, "system.firehose.event_truncation", true}
    refute_received {:firehose_alert, "system.firehose.event_truncation.resolved", _}

    # A third truncating tick past the threshold must NOT re-arm the already
    # armed attention — the alert fires once, not on every truncated tick
    # (arm-once latch).
    rearmed =
      poll_firehose(state,
        request_fun: truncated,
        firehose_truncation_alert_fun: alert_fun
      )

    assert rearmed.firehose_partial_streak == 3
    assert rearmed.firehose_truncation_alert_active
    refute_received {:firehose_alert, "system.firehose.event_truncation", true}

    # One complete window resets the streak and clears the attention.
    complete = fn req ->
      page = request_page(req)
      body = if page == "1", do: [ignored_event("fresh")], else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("complete-etag")}], body: body}}
    end

    resolved =
      poll_firehose(state,
        request_fun: complete,
        firehose_truncation_alert_fun: alert_fun
      )

    assert resolved.firehose_partial_streak == 0
    assert resolved.firehose_truncation_alert_active == false
    assert_received {:firehose_alert, "system.firehose.event_truncation.resolved", false}
  end

  # A single truncated tick (for example the boot reconciliation, or a burst
  # that outpaces the window) is disclosed by the metric but does not itself
  # raise the attention; it takes the sustained threshold.
  test "a single truncated firehose window does not raise the attention" do
    truncated = fn _req ->
      {:ok, %{status: 200, headers: [{"ETag", ~s("partial-etag")}], body: ignored_events("one-shot", 30)}}
    end

    state =
      poll_firehose(%Firehose{},
        request_fun: truncated,
        firehose_truncation_alert_fun: fn _topic, _opts -> :ok end
      )

    assert state.firehose_partial_streak == 1
    assert state.firehose_truncation_alert_active == false
  end

  # After an Orchestrator restart the in-memory latch is lost while the durable
  # alert feed still carries the attention, so a complete window must clear it
  # from the feed half of the resolve condition alone (fresh %State{}).
  test "a complete window clears a persisted truncation attention from a fresh state" do
    :ok = seed_active_feed_attention!("system.firehose.event_truncation")
    parent = self()

    alert_fun = fn topic, opts ->
      send(parent, {:firehose_alert, topic, opts[:needs_attention]})
      :ok
    end

    complete = fn req ->
      page = request_page(req)
      body = if page == "1", do: [ignored_event("fresh")], else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("complete-etag")}], body: body}}
    end

    # Fresh %State{}: the in-memory latch is false, only the durable feed is set.
    state =
      poll_firehose(%Firehose{},
        request_fun: complete,
        firehose_truncation_alert_fun: alert_fun
      )

    assert state.firehose_partial_streak == 0
    assert state.firehose_truncation_alert_active == false
    assert_received {:firehose_alert, "system.firehose.event_truncation.resolved", false}
  end

  # The resolve-once latch: once a resolution has been emitted, a later complete
  # window must not re-emit it even when the resolve path is reached again (the
  # durable feed can still show the attention when the resolve did not persist).
  test "a resolution is emitted at most once while the alert stays resolved" do
    parent = self()

    alert_fun = fn topic, opts ->
      send(parent, {:firehose_alert, topic, opts[:needs_attention]})
      :ok
    end

    complete = fn req ->
      page = request_page(req)
      body = if page == "1", do: [ignored_event("fresh")], else: []
      {:ok, %{status: 200, headers: [{"ETag", ~s("complete-etag")}], body: body}}
    end

    # Already resolved on a previous tick, but the feed still shows the
    # attention (the resolve emit did not persist) — the resolve path is
    # reached again, and the latch must swallow the repeat.
    state = %Firehose{
      firehose_truncation_alert_active: true,
      firehose_truncation_alert_resolution_emitted: true
    }

    next =
      poll_firehose(state,
        request_fun: complete,
        firehose_truncation_alert_fun: alert_fun
      )

    assert next.firehose_truncation_alert_active == false
    assert next.firehose_truncation_alert_resolution_emitted
    refute_received {:firehose_alert, "system.firehose.event_truncation.resolved", _}
  end

  # A failing truncation-alert emit must not silently arm the in-memory latch:
  # the attention stays unarmed so the next truncated tick retries the emit.
  test "a failing truncation alert emit leaves the attention unarmed" do
    counter = :counters.new(1, [:atomics])

    truncated = fn _req ->
      id = :counters.get(counter, 1) + 1
      :counters.add(counter, 1, 1)
      body = Enum.map(1..30, fn n -> ignored_event("gen-#{id}-#{n}") end)
      {:ok, %{status: 200, headers: [{"ETag", ~s("partial-etag")}], body: body}}
    end

    state =
      Enum.reduce(1..2, %Firehose{}, fn _i, acc ->
        poll_firehose(acc,
          request_fun: truncated,
          firehose_truncation_alert_fun: fn _topic, _opts -> {:error, :emit_failed} end
        )
      end)

    assert state.firehose_partial_streak == 2
    assert state.firehose_truncation_alert_active == false
    assert state.firehose_truncation_alert_resolution_emitted == false
  end

  defp poll_firehose(state, opts) do
    :sys.replace_state(Firehose, fn _ -> state end)
    Listeners.poll_firehose(opts)
    :sys.get_state(Firehose)
  end

  defp request_page(%{url: url}) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("page")
  end

  defp ignored_events(prefix, count) do
    Enum.map(1..count, &ignored_event("#{prefix}-#{&1}"))
  end

  defp ignored_event(id) do
    %{
      "id" => id,
      "type" => "IssuesEvent",
      "actor" => %{"login" => "noise"},
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{}
    }
  end

  # Seeds the durable alert ledger (the per-test log root set up by
  # TestSupport) with an active system attention, so the feed half of the
  # truncation resolve condition sees it exactly as after an Orchestrator
  # restart: in-memory latch gone, durable attention still present.
  defp seed_active_feed_attention!(topic) do
    log_path = AlertLedger.path()
    File.mkdir_p!(Path.dirname(log_path))

    File.write!(
      log_path,
      ~s({"event":"alert","timestamp":"2026-08-23T01:00:00Z","topic":"#{topic}","message":"persisted attention","needs_attention":true,"agent":"system"}\n)
    )
  end
end
