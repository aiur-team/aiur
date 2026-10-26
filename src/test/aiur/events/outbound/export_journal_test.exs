defmodule Aiur.Events.Outbound.ExportJournalTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Exchange
  alias Aiur.Events.Outbound.ExportJournal
  alias Aiur.JsonStore

  setup do
    dir = Path.join(System.tmp_dir!(), "outbound-export-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)

    {:ok, dir: dir, journal_path: Path.join(dir, "events.ndjson"), cursor_path: Path.join(dir, "delivery-cursor.json")}
  end

  test "subscribes to allowlisted bus topics and durably replays admitted events", ctx do
    exchange = start_supervised!({Exchange, name: nil})
    journal = start_journal(ctx, exchange: exchange)
    :ok = ExportJournal.subscribe(journal, self())

    internal = %{external: external_event(101, "5695")}
    assert 1 = Exchange.publish("ticket.5695.agent.progress", internal, exchange)
    assert_receive {:durable_record, %{"seq" => 1, "event_id" => "host/default/101", "event" => %{"id" => 101, "seq" => 1}} = record}, 1_000
    assert {:ok, [^record]} = ExportJournal.replay(journal, 0, 10)

    :ok = stop_supervised(ExportJournal)
    restarted = start_journal(ctx, exchange: exchange)
    assert {:ok, [^record]} = ExportJournal.replay(restarted, 0, 10)
  end

  test "bounds pending events without evicting them and compacts only acknowledged records", ctx do
    test = self()

    alert_fun = fn topic, opts ->
      send(test, {:alert, topic, opts})
      :ok
    end

    journal = start_journal(ctx, max_pending_events: 2, alert_fun: alert_fun)

    assert {:ok, 1} = ExportJournal.ingest(journal, %{external: external_event(1, "5695")})
    assert {:ok, 2} = ExportJournal.ingest(journal, %{external: external_event(2, "5695")})
    assert {:error, :capacity_exhausted} = ExportJournal.ingest(journal, %{external: external_event(3, "5695")})
    assert_receive {:alert, "system.outbound_events.queue.capacity", opts}, 1_000
    assert opts[:needs_attention]
    assert {:ok, [%{"seq" => 1}, %{"seq" => 2}]} = ExportJournal.replay(journal, 0, 10)

    JsonStore.write!(ctx.cursor_path, %{"cursor" => 1})
    assert {:ok, 3} = ExportJournal.ingest(journal, %{external: external_event(3, "5695")})
    assert_receive {:alert, "system.outbound_events.queue.capacity.resolved", resolved_opts}, 1_000
    refute resolved_opts[:needs_attention]
    assert {:reset, 2} = ExportJournal.replay(journal, 0, 10)
    assert {:ok, [%{"seq" => 2}, %{"seq" => 3}]} = ExportJournal.replay(journal, 1, 10)

    lines = ctx.journal_path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
  end

  test "refuses to start from an interior-corrupt queue", ctx do
    File.write!(
      ctx.journal_path,
      ~s({"version":1,"seq":1,"event_id":"host/default/1","event":{"instance":"host/default","id":1,"seq":1}}\nnot-json\n)
    )

    Process.flag(:trap_exit, true)

    assert {:error, {:journal_unavailable, {:corrupt, 2, _reason}}} =
             ExportJournal.start_link(journal_options(ctx))
  end

  test "reconciles an append whose durable write completed before the error was reported", ctx do
    append_fun = fn path, record ->
      File.write!(path, Jason.encode!(record) <> "\n", [:append, :sync])
      {:error, :reported_after_write}
    end

    journal = start_journal(ctx, append_fun: append_fun)
    assert {:ok, 1} = ExportJournal.ingest(journal, %{external: external_event(1, "5695")})
    assert {:ok, [%{"seq" => 1, "event_id" => "host/default/1"}]} = ExportJournal.replay(journal, 0, 10)
  end

  defp start_journal(ctx, opts) do
    options = Keyword.merge(journal_options(ctx), opts)
    start_supervised!({ExportJournal, options})
  end

  defp journal_options(ctx) do
    [
      name: nil,
      exchange: nil,
      journal_path: ctx.journal_path,
      cursor_path: ctx.cursor_path,
      instance: "host/default",
      max_pending_events: 10,
      clock: fn -> ~U[2026-10-25 00:00:00Z] end,
      normalize_fun: fn %{external: event}, _now -> {:ok, event} end
    ]
  end

  defp external_event(event_id, ticket_id) do
    %{
      "v" => 1,
      "instance" => "host/default",
      "id" => event_id,
      "topic" => "ticket.#{ticket_id}.agent.progress",
      "class" => "logged",
      "occurred_at" => "2026-10-25T00:00:00Z",
      "observed_at" => "2026-10-25T00:00:00Z",
      "source" => "agent",
      "refs" => %{"ticket" => ticket_id, "job_id" => "run-#{ticket_id}"},
      "attrs" => %{"percent" => 40, "progress_source" => "progress"},
      "payload_version" => 1,
      "anchor" => nil
    }
  end
end
