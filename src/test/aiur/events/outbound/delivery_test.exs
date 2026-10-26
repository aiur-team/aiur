defmodule Aiur.Events.Outbound.DeliveryTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Outbound.{Delivery, ExportJournal}
  alias Aiur.JsonStore

  setup do
    dir = Path.join(System.tmp_dir!(), "outbound-delivery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    {:ok, dir: dir, cursor_path: Path.join(dir, "cursor.json")}
  end

  test "retries the same signed event and advances the cursor only after acknowledgement", ctx do
    journal =
      start_supervised!(
        {ExportJournal,
         name: nil,
         exchange: nil,
         journal_path: Path.join(ctx.dir, "events.ndjson"),
         cursor_path: ctx.cursor_path,
         instance: "host/default",
         normalize_fun: fn %{external: event}, _now -> {:ok, event} end,
         max_pending_events: 10}
      )

    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    test = self()

    request_fun = fn opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      send(test, {:attempt, attempt, Keyword.fetch!(opts, :body)})
      {:ok, %Req.Response{status: if(attempt == 1, do: 503, else: 204)}}
    end

    delivery =
      start_supervised!(
        {Delivery,
         name: nil,
         source: {ExportJournal, journal},
         cursor_path: ctx.cursor_path,
         export: %{webhook_url: "https://consumer.example.test/aiur", subject_id: nil, request_timeout_ms: 1_000, retry_ms: 1},
         secret: "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
         request_fun: request_fun,
         resolve_fun: &resolve_public/2,
         retry_ms: 1,
         retry_max_ms: 4,
         jitter_fun: fn _window -> 0 end}
      )

    assert {:ok, 1} = ExportJournal.ingest(journal, %{external: event()})
    assert_receive {:attempt, 1, body}, 1_000
    assert_receive {:attempt, 2, ^body}, 1_000
    assert :sys.get_state(delivery).cursor == 1
    assert {:ok, %{"cursor" => 1}} = JsonStore.read(ctx.cursor_path)
  end

  test "a permanent 4xx is skipped with attention so the next event can be delivered", ctx do
    journal =
      start_supervised!(
        {ExportJournal,
         name: nil,
         exchange: nil,
         journal_path: Path.join(ctx.dir, "events.ndjson"),
         cursor_path: ctx.cursor_path,
         instance: "host/default",
         normalize_fun: fn %{external: event}, _now -> {:ok, event} end,
         max_pending_events: 10}
      )

    test = self()

    request_fun = fn opts ->
      event_id = opts |> Keyword.fetch!(:body) |> Jason.decode!() |> Map.fetch!("id")
      send(test, {:delivered, event_id})
      {:ok, %Req.Response{status: if(event_id == 101, do: 422, else: 204)}}
    end

    alert_fun = fn topic, opts ->
      send(test, {:alert, topic, opts})
      :ok
    end

    delivery =
      start_supervised!(
        {Delivery,
         name: nil,
         source: {ExportJournal, journal},
         cursor_path: ctx.cursor_path,
         export: %{webhook_url: "https://consumer.example.test/aiur", subject_id: nil, request_timeout_ms: 1_000, retry_ms: 10},
         secret: "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
         request_fun: request_fun,
         resolve_fun: &resolve_public/2,
         alert_fun: alert_fun}
      )

    assert {:ok, 1} = ExportJournal.ingest(journal, %{external: event()})
    assert {:ok, 2} = ExportJournal.ingest(journal, %{external: %{event() | "id" => 102}})
    assert_receive {:delivered, 101}, 1_000
    assert_receive {:alert, "system.outbound_events.delivery.permanent_failure", _opts}, 1_000
    assert_receive {:delivered, 102}, 1_000
    assert :sys.get_state(delivery).cursor == 2
    assert {:ok, %{"cursor" => 2}} = JsonStore.read(ctx.cursor_path)
  end

  defp event do
    %{
      "v" => 1,
      "instance" => "host/default",
      "id" => 101,
      "topic" => "ticket.5695.lifecycle.changed",
      "class" => "live",
      "occurred_at" => "2026-10-25T00:00:00Z",
      "observed_at" => "2026-10-25T00:00:00Z",
      "source" => "legacy",
      "refs" => %{"ticket" => "5695", "job_id" => "run-5695-1"},
      "attrs" => %{"lifecycle" => "running", "lifecycle_source" => "tracker"},
      "payload_version" => 1,
      "anchor" => nil
    }
  end

  defp resolve_public("https://consumer.example.test/aiur", false),
    do: {:ok, "https://93.184.216.34/aiur", "consumer.example.test"}
end
