defmodule Aiur.NewsletterWakeTest do
  use Aiur.TestSupport

  alias Aiur.Executor.StatePaths
  alias Aiur.{ExecutorBindings, ExecutorEvents, ExecutorListener, ExecutorWakeInbox}

  test "newsletter publication replays with file paths after the listener was offline" do
    root = Aiur.TestSupport.tmp_root!("newsletter-wake")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    assert :ok = ExecutorBindings.reconcile()
    assert :ok = ExecutorEvents.validate_publish_topic("system.newsletter.ready")
    assert {:error, :invalid_topic} = ExecutorEvents.validate_publish_topic("system.other.ready")
    payload = %{report_path: Path.join(root, "report.json"), pdf_path: Path.join(root, "newsletter.pdf")}
    assert {:ok, id, _} = ExecutorEvents.publish("system.newsletter.ready", payload)

    inbox =
      start_supervised!(
        {ExecutorWakeInbox,
         name: __MODULE__.Inbox, path: Path.join(root, "wakes.ndjson"), cursor_path: Path.join(root, "cursor.json"), pending_path: Path.join(root, "pending.json"), debounce_ms: 60_000}
      )

    listener =
      start_supervised!({ExecutorListener, name: __MODULE__.Listener, inbox: inbox, resubscribe_interval_ms: :infinity, escalation_interval_ms: :infinity})

    send(inbox, :flush)
    records = ExecutorWakeInbox.pending(inbox)
    assert [%{"topic" => "system.newsletter.ready", "event_id" => ^id, "pdf_path" => pdf, "report_path" => report}] = records
    assert pdf == payload.pdf_path
    assert report == payload.report_path
    assert Jason.decode!(File.read!(StatePaths.watermark_path())) == %{"last_seen_event_id" => id}
    # Redelivery cannot create another wake after a durable replay.
    send(listener, {:event, %{id: id, topic: "system.newsletter.ready", pdf_path: "wrong"}})
    :sys.get_state(listener)
    assert ExecutorWakeInbox.pending(inbox) == records
  end

  test "failed newsletter wakes replay the stage, reason and log path" do
    root = Aiur.TestSupport.tmp_root!("newsletter-failed-wake")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    assert :ok = ExecutorBindings.reconcile()
    payload = %{repo: "owner/repo", date: "2026-10-29", stage: "compile", reason: "render failed", log_path: Path.join(root, "run.log")}
    assert {:ok, id, _} = ExecutorEvents.publish("executor.newsletter.failed", payload)

    inbox =
      start_supervised!(
        {ExecutorWakeInbox,
         name: __MODULE__.Inbox, path: Path.join(root, "wakes.ndjson"), cursor_path: Path.join(root, "cursor.json"), pending_path: Path.join(root, "pending.json"), debounce_ms: 60_000}
      )

    start_supervised!({ExecutorListener, name: __MODULE__.Listener, inbox: inbox, resubscribe_interval_ms: :infinity, escalation_interval_ms: :infinity})
    send(inbox, :flush)
    assert [%{"topic" => "executor.newsletter.failed", "event_id" => ^id} = record] = ExecutorWakeInbox.pending(inbox)
    assert Map.take(record, ~w(repo date stage reason log_path)) == Map.new(payload, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
