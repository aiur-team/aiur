defmodule AiurWeb.Build.TimelineTest do
  use ExUnit.Case, async: true

  alias Aiur.IssueLog.{EventHistory, Format}
  alias Aiur.TestCleanup
  alias AiurWeb.Build.Timeline

  defp identity do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I12", "number" => 12}, {"owner", "repo"}, {"owner", "repo"})
    identity
  end

  test "incremental read passes the high-water mark to durable history" do
    owner = self()

    read = fn identity, opts ->
      send(owner, {:read, identity, opts})
      {:ok, %{events: [%{id: 12, topic: "ticket.12.agent.progress", kind: "self", ts: "2026-10-29T12:00:00Z", summary: "Progress 60%"}], high_water: 12, has_more: false}}
    end

    assert {:ok, %{events: [%{id: 12}], high_water: 12, truncated: false}} = Timeline.read(identity(), 11, read_fun: read)
    assert_received {:read, selected, [after_id: 11, kinds: [:emit, :emit_alert, :consumed, :self, :command], limit: 200]}
    assert selected == identity()
  end

  test "presentation uses real timestamps and retains actor, event kind and progress" do
    events = [
      %{id: 7, topic: "ticket.12.agent.progress", kind: "self", ts: "2026-10-29T12:00:00Z", summary: "Progress 60%"},
      %{id: 8, topic: "ticket.12.agent.phase.work.start", kind: "self", ts: "2026-10-29T12:01:00Z", summary: ""},
      %{id: 9, topic: "ticket.12.agent.phase.work.start", kind: "consumed", ts: "2026-10-29T12:01:00Z", summary: ""}
    ]

    timeline = Timeline.present(identity(), events)
    assert timeline.high_water == 9
    assert Enum.map(timeline.items, & &1.at) == [1_793_275_200_000, 1_793_275_260_000, 1_793_275_260_000]
    assert [%{actor: "Aiur agent", kind: :progress, percent: 60} | _] = timeline.items
    assert Enum.any?(timeline.items, &(&1.actor == "Aiur daemon" and &1.kind == :consume))
    assert [%{label: "Work", start: 1_793_275_260_000, finish: nil}] = timeline.phases
  end

  test "durable event pages advance a high-water mark without rereading old events" do
    path = Path.join(System.tmp_dir!(), "timeline-#{System.unique_integer([:positive])}.events.log")
    File.write!(path, "2026-10-29T12:00:00Z [event:self] id=4 pct=40 ticket.12.agent.progress\n2026-10-29T12:01:00Z [event:emit] id=5 ticket.12.pr.opened\n")
    on_exit(fn -> TestCleanup.rm_rf!(path) end)

    assert {:ok, %{events: [%{id: 4}], high_water: 4, has_more: true}} = EventHistory.read_event_page(path, limit: 1)
    assert {:ok, %{events: [%{id: 5}], high_water: 5, has_more: false}} = EventHistory.read_event_page(path, after_id: 4, limit: 1)
  end

  test "timeline marker persistence carries the real progress percentage" do
    event = %{id: 4, topic: "ticket.12.agent.progress", percent: 75, observed_at: ~U[2026-10-29 12:00:00Z]}
    line = Format.format_event_marker(:self, event)
    assert line =~ "pct=75"
    path = Path.join(System.tmp_dir!(), "timeline-progress-#{System.unique_integer([:positive])}.events.log")
    File.write!(path, line)
    on_exit(fn -> TestCleanup.rm_rf!(path) end)
    assert {:ok, %{events: [%{percent: 75}]}} = EventHistory.read_event_page(path, kinds: [:self])
  end

  test "command records retain their complete command text without output" do
    path = Path.join(System.tmp_dir!(), "timeline-command-#{System.unique_integer([:positive])}.events.log")
    command = "mise exec -- mix test --max-cases 4"
    encoded = Base.url_encode64(command, padding: false)
    File.write!(path, "2026-10-29T12:00:00Z [event:command] id=4 cmd=#{encoded} ticket.12.agent.command\n")
    on_exit(fn -> TestCleanup.rm_rf!(path) end)

    assert {:ok, %{events: [%{kind: "command", summary: ^command}]}} = EventHistory.read_event_page(path, kinds: [:command])
  end

  test "cache append reuses prior segments and accepts only newer event ids" do
    old = %{id: 4, topic: "ticket.12.pr.opened", kind: "emit", ts: "2026-10-29T12:00:00Z", summary: ""}
    repeated = %{old | summary: "duplicate"}
    new = %{old | id: 5, topic: "ticket.12.pr.merged"}
    assert %{events: [^old, ^new], high_water: 5} = Timeline.append_cache(%{events: [old], high_water: 4}, [repeated, new])
  end
end
