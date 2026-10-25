defmodule Aiur.Events.Outbound.PublisherAdmissionTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.Outbound.ExportJournal
  alias Aiur.Events.Outbound.Producer
  alias Aiur.Events.Publisher
  alias Aiur.TrackerIdentity

  setup do
    dir = Path.join(System.tmp_dir!(), "outbound-publisher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Publisher.set_tracked_fn(fn _issue -> true end)

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(dir)
      Publisher.set_tracked_fn(fn _issue -> true end)
    end)

    journal =
      start_supervised!({ExportJournal, journal_path: Path.join(dir, "events.ndjson"), cursor_path: Path.join(dir, "cursor.json"), max_pending_events: 10})

    {:ok, dir: dir, journal: journal}
  end

  test "the publisher durably admits a normalized event before exchange fan-out", %{journal: journal} do
    identity = identity()

    assert {:ok, id, _subscribers} =
             Publisher.publish("ticket.5695.agent.progress", %{"percent" => 40},
               issue_number: 5695,
               identity: identity,
               observation_source: %{kind: :agent_event, name: "progress"},
               observation_provenance: %{run_id: "run-5695-1"},
               occurred_at: ~U[2026-10-25 00:00:00Z],
               observation_clock: fn -> ~U[2026-10-25 00:00:01Z] end
             )

    assert {:ok, [%{"seq" => 1, "event" => event}]} = ExportJournal.replay(journal, 0, 10)
    assert event["event_id"] == "evt_#{id}"
    assert event["event_type"] == "ticket.progress.changed"
    assert event["ticket_id"] == "5695"
  end

  test "the outbound producer preserves trusted correlation through publisher admission", %{journal: journal} do
    identity = identity()
    parent = self()

    Publisher.set_tracked_fn(fn issue_number ->
      send(parent, {:tracked, issue_number})
      issue_number == "5695"
    end)

    assert :ok =
             Producer.publish(
               "ticket.5695.lifecycle.changed",
               %{
                 outbound_event: %{
                   kind: :ticket_lifecycle,
                   data: %{
                     "lifecycle" => "running",
                     "source" => "tracker",
                     "observed_at" => "2026-10-25T00:00:00Z"
                   }
                 }
               },
               identity,
               "run-5695-1",
               ~U[2026-10-25 00:00:00Z]
             )

    assert_receive {:tracked, "5695"}, 1_000
    assert {:ok, [%{"event" => event}]} = ExportJournal.replay(journal, 0, 10)
    assert event["event_type"] == "ticket.lifecycle.changed"
    assert event["ticket_id"] == "5695"
    assert event["job_id"] == "run-5695-1"
    assert event["data"]["lifecycle"] == "running"
  end

  defp identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "I_5695",
      database_id: 5695,
      identifier: "5695",
      reason: nil
    }
  end
end
