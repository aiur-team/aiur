defmodule Aiur.AgentList.DebugEventsTickerTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentList.Renderer
  alias Aiur.Events.DebugLog

  defp build_state(overrides) do
    %{
      summaries: [],
      selection_index: 0,
      selection_focus: :agents,
      columns: 80,
      rows: 24,
      help_visible?: false,
      project_label: nil,
      dashboard_url: nil,
      refresh_label: nil,
      debug_mode?: true,
      perf_summary: %{
        agent_list_ready_ms: 100,
        chat_pane_visible_ms: nil,
        opencode_render_ms: nil
      },
      warmth_events: [],
      debug_events: []
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "events section (always on, bordered)" do
    test "renders events inside the AgentList box even when debug_mode? is false (always-on now)" do
      state =
        build_state(
          debug_mode?: false,
          debug_events: [debug_entry(:publish, topic: "ticket.42.branch.push")]
        )

      output = state |> Renderer.render() |> IO.iodata_to_binary()

      # Single box: AgentList top + bottom curved corners.
      assert output =~ "╭─ AIUR"
      assert output =~ "╰"

      # No separate "Events" box header anymore.
      refute output =~ "╭─ Events"

      # Event line renders inside the box, separated from the table
      # rows by a `├──┤` divider.
      assert output =~ "├"
      assert output =~ "💬 42"
    end

    test "events render inline with the agent table" do
      events = [
        debug_entry(:read, topic: "ticket.42.branch.push", id: 4290, identifier: "42"),
        debug_entry(:receive, topic: "ticket.42.branch.push", id: 4287, identifier: "99"),
        debug_entry(:publish, topic: "ticket.42.branch.push", id: 4287)
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      # Inside the same box; divider above the events block.
      assert output =~ "├"

      # Per-line format:
      #   - publish branch.push with no commits payload → terse "pushed"
      #     (no trailing colon).
      #   - cross-ticket receive uses ← arrow, not "Agent received from".
      #   - read uses minimal "Agent ingested".
      assert output =~ "💬 42 pushed"
      assert output =~ "📬 99 ← 42: pushed"
      assert output =~ "📄 42 ingested: pushed"
    end

    test "newest event renders BELOW older events (anchored to bottom)" do
      events = [
        debug_entry(:read, topic: "ticket.42.branch.push", id: 3),
        debug_entry(:receive, topic: "ticket.42.branch.push", id: 2, identifier: "99"),
        debug_entry(:publish, topic: "ticket.42.branch.push", id: 1)
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      publish_pos = :binary.match(output, "💬 42 pushed") |> elem(0)
      receive_pos = :binary.match(output, "📬 99 ← 42: pushed") |> elem(0)
      read_pos = :binary.match(output, "📄 42 ingested: pushed") |> elem(0)

      assert publish_pos < receive_pos
      assert receive_pos < read_pos
    end

    test "hides oldest events when section would exceed budget" do
      events =
        for i <- 100..1, do: debug_entry(:publish, topic: "ticket.#{i}.branch.push", id: i)

      state = build_state(rows: 24, debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 100 pushed"
      refute output =~ "💬 1 pushed"
    end

    test "events block collapses when pane has no remaining vertical budget" do
      events = [debug_entry(:publish, topic: "ticket.1.branch.push", id: 1)]
      state = build_state(rows: 6, debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      refute output =~ "💬 1 pushed"
    end

    test "branch.push with commits payload renders count + last commit message" do
      events = [
        debug_entry(:publish,
          topic: "ticket.42.branch.push",
          id: 1,
          body: %{
            "commits" => [
              %{"message" => "first commit"},
              %{"message" => "Add function_a/0 returning 42"}
            ]
          }
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 42 pushed 2 commits, last: \"Add function_a/0 returning 42\""
    end

    test "pr.opened extracts the PR title" do
      events = [
        debug_entry(:publish,
          topic: "ticket.42.pr.opened",
          id: 1,
          body: %{"pr" => %{"title" => "feat: add function_a"}}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 42 opened a PR: \"feat: add function_a\""
    end

    test "self-receive of agent.* echoes is suppressed (publish covers it)" do
      events = [
        debug_entry(:publish,
          topic: "ticket.140.agent.phase.work.start",
          id: 1,
          body: %{"message" => "starting"}
        ),
        # Same agent's own subscription echoing back — should NOT render.
        debug_entry(:receive,
          topic: "ticket.140.agent.phase.work.start",
          id: 1,
          identifier: "140"
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 140 started work"
      refute output =~ "📬 140 ← 140"
      refute output =~ "Agent received from 140"
    end

    test "self-receive of an issue.commented is kept and reads `new Issue comment:`" do
      events = [
        debug_entry(:receive,
          topic: "ticket.140.issue.commented",
          id: 1,
          identifier: "140",
          body: %{"comment" => %{"body" => "Looks good to me"}}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "📬 140 new Issue comment: \"Looks good to me\""
    end

    test "agent.progress renders as `Estimated progress: N% done`" do
      events = [
        debug_entry(:publish,
          topic: "ticket.101.agent.progress",
          id: 1,
          body: %{"percent" => 80, "label" => "work: starting impl"}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 101 Estimated progress: 80% done \"work: starting impl\""
      refute output =~ "Agent progress"
    end

    test "agent.progress.checkin renders as `Check-in: N% done`" do
      events = [
        debug_entry(:publish,
          topic: "ticket.140.agent.progress.checkin",
          id: 1,
          body: %{"percent" => 30, "label" => "work: implementing"}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 140 Check-in: 30% done"
    end

    test "agent.phase.work.start drops `Agent ` prefix" do
      events = [
        debug_entry(:publish,
          topic: "ticket.99.agent.phase.work.start",
          id: 1,
          body: %{"message" => "implementing"}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 99 started work:"
      refute output =~ "Agent started"
    end

    test "operator.progress_request renders as `check-in requested`" do
      events = [
        debug_entry(:publish,
          topic: "ticket.99.operator.progress_request",
          id: 1,
          body: %{"message" => "operator ping"}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "💬 99 check-in requested"
      refute output =~ "operator.progress_request"
    end

    test "read events show source ticket and body summary" do
      events = [
        debug_entry(:read,
          topic: "ticket.100.branch.push",
          id: 1,
          identifier: "99",
          body: %{
            "commits" => [%{"message" => "Add function_a/0 returning 42"}]
          }
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~
               "📄 99 ingested 100: pushed 1 commit, last: \"Add function_a/0 returning 42\""
    end

    test "read events of the agent's own publish drop the source id" do
      events = [
        debug_entry(:read,
          topic: "ticket.42.branch.push",
          id: 1,
          identifier: "42",
          body: %{"commits" => [%{"message" => "hi"}]}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "📄 42 ingested: pushed 1 commit, last: \"hi\""
      refute output =~ "ingested 42:"
    end

    test "multi-line comment bodies collapse to one line with ellipsis" do
      events = [
        debug_entry(:receive,
          topic: "ticket.140.issue.commented",
          id: 1,
          identifier: "140",
          body: %{
            "comment" => %{
              "body" => "## Agent Workpad\n\n```text\nd:/home/orangekid/code/aiur-workspaces/100\napplekid:/home/orangekid/code/aiur-workspaces/100\n```"
            }
          }
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      refute output =~ "Workpad\n", "embedded newlines must be collapsed"
      refute output =~ "```text\n", "code fences must not survive into the event row"
      assert output =~ "📬 140 new Issue comment: \"## Agent Workpad ```text d:/"
    end

    test "self-receive of a pr.review_comment reads `new PR comment:`" do
      events = [
        debug_entry(:receive,
          topic: "ticket.140.pr.review_comment",
          id: 1,
          identifier: "140",
          body: %{"comment" => %{"body" => "nit on line 42"}}
        )
      ]

      state = build_state(debug_events: events)
      output = state |> Renderer.render() |> IO.iodata_to_binary()

      assert output =~ "📬 140 new PR comment: \"nit on line 42\""
    end
  end

  describe "over-width truncation with OSC 8 hyperlinks" do
    test "an over-width event line truncates with an ellipsis instead of vanishing" do
      # The subject id is wrapped in an OSC 8 hyperlink whose URL is ~50
      # invisible bytes. On a narrow pane the visible line exceeds the box
      # width and must truncate. The width budget counts VISIBLE columns —
      # if the hyperlink's escape bytes are miscounted against it, the
      # truncation cuts inside the escape sequence, the terminal swallows
      # the broken OSC 8 run, and the whole line disappears. The line must
      # survive as a deterministic ellipsis-truncation instead.
      long_msg = String.duplicate("x", 80)

      events = [
        debug_entry(:publish,
          topic: "ticket.101.branch.push",
          id: 1,
          body: %{"commits" => [%{"message" => "first " <> long_msg}]}
        )
      ]

      state =
        build_state(
          columns: 50,
          project_label: "its-everdred/aiur",
          debug_events: events
        )

      visible =
        state
        |> Renderer.render()
        |> IO.iodata_to_binary()
        |> strip_ansi()

      assert visible =~ "101 pushed", "over-width line was hidden instead of truncated"
      assert visible =~ "…", "truncated line must end with an ellipsis"
    end
  end

  # Mirror of Renderer.strip_ansi/1 — drops CSI colour runs and the
  # terminator-bearing OSC 8 hyperlink wrappers, leaving only the visible
  # text. A broken (un-terminated) OSC 8 run is intentionally NOT stripped,
  # so a regression that emits one leaves the garbled escape (and no visible
  # body) in the result.
  defp strip_ansi(text) do
    text
    |> then(&Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, &1, ""))
    |> then(&Regex.replace(~r/\e\]8;;[^\e\a]*(\e\\|\a)/, &1, ""))
  end

  describe "persistence across render cycles" do
    test "events survive consecutive renders with unchanged debug_events" do
      events = [debug_entry(:publish, topic: "ticket.42.branch.push", id: 42)]
      state = build_state(debug_events: events)

      first = state |> Renderer.render() |> IO.iodata_to_binary()
      assert first =~ "💬 42 pushed"

      second = state |> Renderer.render() |> IO.iodata_to_binary()
      assert second =~ "💬 42 pushed"
    end
  end

  describe "App render() pipes debug_events through" do
    test "Renderer reads debug_events from the state map" do
      events = [debug_entry(:publish, topic: "ticket.7.branch.push", id: 7)]
      with_events = build_state(debug_events: events)
      without_events = build_state(debug_events: [])

      with_out = with_events |> Renderer.render() |> IO.iodata_to_binary()
      without_out = without_events |> Renderer.render() |> IO.iodata_to_binary()

      assert with_out =~ "💬 7 pushed"
      refute without_out =~ "💬 7 pushed"
    end
  end

  describe "DebugLog broadcast" do
    test "subscribers receive {:event_debug, entry} on publish kind" do
      DebugLog.subscribe()
      DebugLog.broadcast(:publish, "ticket.7.branch.push", id: 99)
      assert_receive {:event_debug, %{kind: :publish, topic: "ticket.7.branch.push", id: 99}}, 500
      DebugLog.unsubscribe()
    end

    test "receive kind carries identifier" do
      DebugLog.subscribe()
      DebugLog.broadcast(:receive, "ticket.7.branch.push", id: 100, identifier: "7")

      assert_receive {:event_debug, %{kind: :receive, identifier: "7"}}, 500
      DebugLog.unsubscribe()
    end
  end

  defp debug_entry(kind, opts \\ []) do
    %{
      kind: kind,
      topic: Keyword.get(opts, :topic, "ticket.1.branch.push"),
      id: Keyword.get(opts, :id),
      identifier: Keyword.get(opts, :identifier),
      body: Keyword.get(opts, :body),
      at: System.monotonic_time(:millisecond)
    }
  end
end
