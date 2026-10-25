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

    _delivery =
      start_supervised!(
        {Delivery,
         name: nil,
         source: {ExportJournal, journal},
         cursor_path: ctx.cursor_path,
         export: %{webhook_url: "https://consumer.example.test/aiur", subject_id: nil, request_timeout_ms: 1_000, retry_ms: 1},
         secret: "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
         request_fun: request_fun,
         retry_ms: 1}
      )

    assert {:ok, 1} = ExportJournal.ingest(journal, %{external: event()})
    assert_receive {:attempt, 1, body}, 1_000
    assert_receive {:attempt, 2, ^body}, 1_000
    assert eventually(fn -> JsonStore.read(ctx.cursor_path) == {:ok, %{"cursor" => 1}} end)
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(5)
            eventually(fun, attempts - 1)
          )
      )

  defp event do
    %{
      "contract" => "aiur.ticket_lifecycle_event",
      "contract_version" => 1,
      "event_id" => "evt_101",
      "event_type" => "ticket.lifecycle.changed",
      "emitted_at" => "2026-10-25T00:00:00Z",
      "ticket_id" => "5695",
      "data" => %{"lifecycle" => "running", "source" => "tracker", "observed_at" => "2026-10-25T00:00:00Z"}
    }
  end
end
