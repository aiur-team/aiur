defmodule AiurWeb.Build.TimelineTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.TicketTimelineProvider
  alias Aiur.IssueLog.{CommandRecorder, EventHistory, Format}
  alias Aiur.{TestCleanup, TrackerIdentity}
  alias AiurWeb.Build.Timeline

  defp identity do
    {:ok, identity} = Aiur.TrackerIdentity.from_github(%{"node_id" => "I12", "number" => 12}, {"owner", "repo"}, {"owner", "repo"})
    identity
  end

  defp timestamp(offset_seconds \\ 0), do: DateTime.utc_now() |> DateTime.add(offset_seconds, :second) |> DateTime.to_iso8601()
  defp unix(ts), do: ts |> DateTime.from_iso8601() |> elem(1) |> DateTime.to_unix(:millisecond)

  test "incremental read passes the high-water mark to durable history" do
    owner = self()

    read = fn identity, opts ->
      send(owner, {:read, identity, opts})
      {:ok, %{events: [%{id: 12, topic: "ticket.12.agent.progress", kind: "self", ts: timestamp(), summary: "Progress 60%"}], high_water: 12, has_more: false}}
    end

    assert {:ok, %{events: [%{id: 12}], high_water: 12, truncated: false}} = Timeline.read(identity(), 11, read_fun: read)
    assert_received {:read, selected, [after_id: 11, kinds: [:emit, :emit_alert, :consumed, :self, :command], limit: 200]}
    assert selected == identity()
  end

  test "first build drains all event pages and later pages start at the prior high-water mark" do
    owner = self()

    read = fn _identity, opts ->
      send(owner, {:page, Keyword.fetch!(opts, :after_id)})

      case Keyword.fetch!(opts, :after_id) do
        0 -> {:ok, %{events: [%{id: 200}], high_water: 200, has_more: true}}
        200 -> {:ok, %{events: [%{id: 400}], high_water: 400, has_more: false}}
      end
    end

    assert {:ok, %{events: [%{id: 200}, %{id: 400}], high_water: 400, truncated: false}} = Timeline.read(identity(), 0, read_fun: read)
    assert_received {:page, 0}
    assert_received {:page, 200}
    refute_received {:page, 400}
  end

  test "durable timeline provider validates ticket identity" do
    assert {:error, :invalid_identity} = TicketTimelineProvider.read_page(%TrackerIdentity{status: :invalid}, [])
  end

  test "presentation uses real timestamps and retains actor, event kind and progress" do
    events = [
      %{id: 7, topic: "ticket.12.agent.progress", kind: "self", ts: timestamp(), summary: "Progress 60%"},
      %{id: 10, topic: "ticket.12.agent.progress.checkin", kind: "self", ts: timestamp(120), summary: "status update"},
      %{id: 8, topic: "ticket.12.agent.phase.work.start", kind: "self", ts: timestamp(60), summary: ""},
      %{id: 9, topic: "ticket.12.agent.phase.work.start", kind: "consumed", ts: timestamp(60), summary: ""}
    ]

    timeline = Timeline.present(identity(), events)
    assert timeline.high_water == 10
    assert Enum.map(timeline.items, & &1.at) == events |> Enum.map(&unix(&1.ts)) |> Enum.sort()
    assert [%{actor: "Aiur agent", kind: :emit, status: :progress, percent: 60} | _] = timeline.items
    assert [%{percent: 60}] = timeline.progress
    assert Enum.any?(timeline.items, &(&1.actor == "Aiur daemon" and &1.kind == :consume))
    phase_start = Enum.at(timeline.items, 1).at
    assert [%{label: "Work", start: ^phase_start, finish: nil}] = timeline.phases
  end

  test "review, CI, retry and pause events have distinct sad-path items" do
    base = %{kind: "emit", ts: timestamp(), summary: ""}

    events = [
      Map.merge(base, %{id: 1, topic: "ticket.12.pr.review_comment", review_state: "CHANGES_REQUESTED", summary: "Request changes at deadbeef"}),
      Map.merge(base, %{id: 2, topic: "ticket.12.pr.review_comment", review_state: "CHANGES_REQUESTED", summary: "Executor: CI on this head is red"}),
      Map.merge(base, %{id: 32, topic: "ticket.12.pr.review_comment", review_state: "APPROVED", summary: "The changes requested earlier are fixed"}),
      Map.merge(base, %{id: 3, topic: "ticket.12.ci.failed", summary: "test-linux failed"}),
      Map.merge(base, %{
        id: 30,
        topic: "ticket.12.ci.merge_group.failed",
        summary: "Merge-group run failed; PR was removed from the merge queue",
        ci_checks: [%{name: "compile", url: "https://github.com/owner/repo/actions/runs/123"}]
      }),
      Map.merge(base, %{id: 31, topic: "ticket.12.ci.merge_group.requeued", summary: "Merge-group run requeued PR #12"}),
      Map.merge(base, %{id: 4, topic: "ticket.12.agent.retry_exhausted", summary: "retry exhausted"}),
      Map.merge(base, %{id: 5, topic: "ticket.12.agent.paused", summary: "max_agent_duration"}),
      Map.merge(base, %{id: 6, topic: "ticket.12.agent.attention.dispatch-declined", summary: "capacity"}),
      Map.merge(base, %{id: 7, topic: "ticket.12.agent.attention.budget-hold-persistent", summary: "held"}),
      Map.merge(base, %{id: 8, topic: "ticket.12.issue.label.added.agent.rework", summary: "agent:rework"}),
      Map.merge(base, %{id: 9, topic: "ticket.12.lifecycle.changed", summary: "paused"})
    ]

    items = Timeline.present(identity(), events).items
    assert [%{kind: :emit, status: :rework, round: 1}, %{kind: :emit, status: :rework, round: 2}] = Enum.filter(items, &(Map.get(&1, :status) == :rework))
    assert Enum.any?(items, &(Map.get(&1, :review_state) == "APPROVED" and Map.get(&1, :status) != :rework and &1.label =~ "Review APPROVED"))
    assert Enum.any?(items, &(&1.status == :ci_failure and &1.label =~ "failed"))
    assert Enum.any?(items, &(&1.status == :merge_group_failure and &1.label =~ "compile" and &1.label =~ "removed from queue" and &1.run_url =~ "/actions/runs/123"))
    assert Enum.any?(items, &(&1.status == :merge_group_requeue and &1.label =~ "requeued"))
    assert Enum.any?(items, &(&1.status == :retry_exhausted))
    assert Enum.any?(items, &(&1.status == :pause))
    assert Enum.any?(items, &(&1.status == :dispatch_decline))
    assert Enum.any?(items, &(&1.status == :budget_hold))
    assert Enum.any?(items, &(&1.status == :label_transition))
    assert Enum.any?(items, &(&1.status == :label_transition and &1.actor == "Aiur daemon"))
    assert Enum.any?(items, &(&1.status == :lifecycle))
  end

  test "durable event pages advance a high-water mark without rereading old events" do
    path = Path.join(System.tmp_dir!(), "timeline-#{System.unique_integer([:positive])}.events.log")
    File.write!(path, "#{timestamp()} [event:self] id=4 pct=40 ticket.12.agent.progress\n#{timestamp(60)} [event:emit] id=5 ticket.12.pr.opened\n")
    on_exit(fn -> TestCleanup.rm_rf!(path) end)

    assert {:ok, %{events: [%{id: 4}], high_water: 4, has_more: true}} = EventHistory.read_event_page(path, limit: 1)
    assert {:ok, %{events: [%{id: 5}], high_water: 5, has_more: false}} = EventHistory.read_event_page(path, after_id: 4, limit: 1)
  end

  test "timeline marker persistence carries the real progress percentage" do
    event = %{id: 4, topic: "ticket.12.agent.progress", percent: 75, observed_at: DateTime.utc_now()}
    line = Format.format_event_marker(:self, event)
    assert line =~ "pct=75"
    path = Path.join(System.tmp_dir!(), "timeline-progress-#{System.unique_integer([:positive])}.events.log")
    File.write!(path, line)
    on_exit(fn -> TestCleanup.rm_rf!(path) end)
    assert {:ok, %{events: [%{percent: 75}]}} = EventHistory.read_event_page(path, kinds: [:self])
  end

  test "CI markers retain safe check names and a query-free run link" do
    event = %{
      id: 14,
      topic: "ticket.12.ci.failed",
      checks: [%{name: "linux-tests", url: "https://github.com/owner/repo/actions/runs/123?token=private"}, %{name: "secret=sk-aaaaaaaaaaaaaaaaaaaa", url: "https://evil.test/actions/runs/9"}],
      observed_at: DateTime.utc_now()
    }

    line = Format.format_event_marker(:emit, event)
    path = Path.join(System.tmp_dir!(), "timeline-ci-#{System.unique_integer([:positive])}.events.log")
    File.write!(path, line)
    on_exit(fn -> TestCleanup.rm_rf!(path) end)

    assert {:ok, %{events: [stored]}} = EventHistory.read_event_page(path, kinds: [:emit])
    assert stored.ci_checks == [%{name: "linux-tests", url: "https://github.com/owner/repo/actions/runs/123"}, %{name: "secret=[REDACTED:sk]"}]
    [item | _] = Timeline.present(identity(), [stored]).items
    assert item.run_url == "https://github.com/owner/repo/actions/runs/123"
  end

  test "command records retain their complete command text without output" do
    path = Path.join(System.tmp_dir!(), "timeline-command-#{System.unique_integer([:positive])}.events.log")
    command = "mise exec -- mix test --max-cases 4"
    encoded = Base.url_encode64(command, padding: false)
    File.write!(path, "#{timestamp()} [event:command] id=4 cmd=#{encoded} ticket.12.agent.command\n")
    on_exit(fn -> TestCleanup.rm_rf!(path) end)

    assert {:ok, %{events: [%{kind: "command", summary: ^command}]}} = EventHistory.read_event_page(path, kinds: [:command])
  end

  test "cache append reuses prior segments and accepts only newer event ids" do
    old = %{id: 4, topic: "ticket.12.pr.opened", kind: "emit", ts: timestamp(), summary: ""}
    repeated = %{old | summary: "duplicate"}
    new = %{old | id: 5, topic: "ticket.12.pr.merged"}
    assert %{events: [^old, ^new], appended: [^new], high_water: 5} = Timeline.append_cache(%{events: [old], high_water: 4}, [repeated, new])
  end

  test "the Build Order timeline cache is shared across ticket detail sockets" do
    key = {:timeline_test, System.unique_integer([:positive])}
    old = %{id: 10, topic: "ticket.12.pr.opened", kind: "emit", ts: timestamp(), summary: ""}
    new = %{old | id: 11, topic: "ticket.12.pr.merged"}

    assert :ok = TicketTimelineProvider.cache(key, %{events: [old], high_water: 10})
    assert %{events: [^old], high_water: 10} = TicketTimelineProvider.cached(key)
    assert :ok = TicketTimelineProvider.cache(key, %{events: [new], high_water: 11})
    assert %{events: [^old, ^new], high_water: 11} = TicketTimelineProvider.cached(key)
  end

  test "command recorder redacts credentials before journal persistence" do
    token = "ghp_123456789012345678901234567890123456"
    command = CommandRecorder.sanitize_command("GH_TOKEN=#{token} gh issue view 12")
    assert command == "GH_TOKEN=[REDACTED:credential] gh issue view 12"
    refute command =~ token

    assert CommandRecorder.sanitize_command("curl -H 'Authorization: Bearer arbitrary-value' https://example.test") ==
             "curl -H 'Authorization: Bearer [REDACTED:credential]' [REDACTED:url]"
  end
end
