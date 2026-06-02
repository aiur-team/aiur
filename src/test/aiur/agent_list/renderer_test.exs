defmodule Aiur.AgentList.RendererTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer

  defp render(state), do: IO.iodata_to_binary(Renderer.render(state))

  defp visible(text), do: Regex.replace(~r/\e\[[?0-9;]*[A-Za-z]/, text, "")

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        summaries: [],
        selection_index: 0,
        columns: 60,
        rows: 20,
        project_label: nil,
        dashboard_url: nil,
        refresh_label: nil,
        agent_kind: nil,
        agent_count: nil,
        max_agents: nil
      },
      overrides
    )
  end

  test "renders the bordered AIUR title" do
    out = render(base_state()) |> visible()

    assert out =~ "╭─ AIUR"
    assert out =~ "╰"
  end

  test "renders the metadata block with project, dashboard, and refresh chip" do
    out =
      render(
        base_state(%{
          project_label: "applekid/aiur",
          dashboard_url: "http://127.0.0.1:4000/",
          refresh_label: "15s"
        })
      )
      |> visible()

    assert out =~ "Project:"
    assert out =~ "applekid/aiur"
    assert out =~ "Dashboard:"
    assert out =~ "http://127.0.0.1:4000/"
    # Refresh now lives in the title row as a 🔄 chip on the right.
    assert out =~ "🔄 in 15s"
  end

  test "falls back to n/a placeholders when metadata is missing" do
    out = render(base_state()) |> visible()

    assert out =~ "Agents: n/a"
    assert out =~ "Project: n/a"
    assert out =~ "Dashboard: n/a"
    assert out =~ "🔄 in 0s"
    refute out =~ "🔄 n/a"
  end

  test "renders empty refresh labels as in 0s" do
    out = render(base_state(%{refresh_label: ""})) |> visible()

    assert out =~ "🔄 in 0s"
    refute out =~ "🔄 n/a"
  end

  test "shows agent count and max in the Agents row" do
    out =
      render(
        base_state(%{
          summaries: [
            %{identifier: "MT-1", status: :running, alert_count: 0},
            %{identifier: "MT-2", status: :running, alert_count: 0}
          ],
          agent_kind: "claude",
          agent_count: 2,
          max_agents: 5
        })
      )
      |> visible()

    assert out =~ "Agents:"
    assert out =~ "claude (2/5)"
  end

  test "focused max display highlights editable value and shows arrow affordances" do
    out =
      render(
        base_state(%{
          agent_kind: "codex",
          agent_count: 1,
          max_agents: 2,
          selection_focus: :max_agents
        })
      )
      |> visible()

    assert out =~ "codex (1/[2])"
    assert out =~ "← →"
  end

  test "max alert applies terminal highlight styling" do
    raw =
      render(
        base_state(%{
          agent_kind: "codex",
          agent_count: 2,
          max_agents: 2,
          max_agents_alert?: true
        })
      )

    assert raw =~ IO.ANSI.red()
    assert raw =~ IO.ANSI.reverse()
  end

  test "renders the agent table header columns" do
    out =
      render(base_state(%{summaries: [%{identifier: "MT-1", status: :running, alert_count: 0}]}))
      |> visible()

    # ID is labelled; tag-circle and state-circle columns use
    # emoji-only cells and therefore have no header text. Column
    # order is ID → tag-circle → state-circle → TITLE → LATEST →
    # PROGRESS → TIME.
    assert out =~ ~r/ID\s+TITLE\s+LATEST\s+PROGRESS\s+TIME/
  end

  test "shows '(no agents running)' when the list is empty" do
    out = render(base_state()) |> visible()
    assert out =~ "(no agents running)"
  end

  test "renders one agent per row and marks the selected row" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0},
      %{identifier: "MT-2", status: :running, alert_count: 0}
    ]

    out = render(base_state(%{summaries: summaries, selection_index: 1})) |> visible()

    assert out =~ "  MT-1"
    assert out =~ "▶ MT-2"
  end

  test "does not mark an agent row when the max control is focused" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          selection_index: 0,
          selection_focus: :max_agents,
          agent_kind: "codex",
          agent_count: 1,
          max_agents: 2
        })
      )
      |> visible()

    assert out =~ "codex (1/[2])"
    refute out =~ "▶ MT-1"
  end

  test "renders state with a colored circle emoji" do
    summaries = [
      %{
        identifier: "MT-9",
        status: :running,
        alert_count: 0,
        work_state: :paused
      }
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()

    # Paused agent state surfaces as a pause glyph (⏸️ in the state
    # column). Working agents would render as 🟢.
    assert out =~ "⏸️"
  end

  test "working agents render the ready marker, not the tag color" do
    summaries = [
      %{
        identifier: "MT-WORK",
        status: :running,
        alert_count: 0,
        tag: "agent:todo",
        work_state: :working
      }
    ]

    attached =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{"MT-WORK" => %{attach_count: 1, visible_in: 1}},
          agents_with_content: MapSet.new(["MT-WORK"])
        })
      )
      |> visible()

    visible_now =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{"MT-WORK" => %{attach_count: 1, visible_in: 1}},
          agents_with_content: MapSet.new(["MT-WORK"]),
          opened_panes: MapSet.new(["MT-WORK"])
        })
      )
      |> visible()

    assert attached =~ "⚪"
    assert visible_now =~ "🟢"
    refute attached =~ "🟡"
  end

  test "running working agents transition ⏳ → 🔘 → ⚪ → 🟢 based on slot warmup + agent content" do
    summaries = [
      %{
        identifier: "MT-WARM",
        status: :running,
        alert_count: 0,
        work_state: :working
      },
      %{
        identifier: "MT-OPEN",
        status: :running,
        alert_count: 0,
        work_state: :working
      }
    ]

    hourglass =
      render(base_state(%{summaries: summaries, attach_state: %{}})) |> visible()

    # Slot painted for MT-WARM but the agent hasn't emitted any
    # transcript content yet — instant-open but pane will show only
    # Build chrome until the codex turn produces something. That's
    # the 🔘 case under the new semantics (was the old ⚪ trap that
    # promised "instant useful open" and delivered an empty pane).
    primed_empty =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{
            "MT-WARM" => %{attach_count: 1, visible_in: 2},
            "MT-OPEN" => %{attach_count: 1, visible_in: 1}
          },
          agents_with_content: MapSet.new(["MT-OPEN"]),
          opened_panes: MapSet.new(["MT-OPEN"])
        })
      )
      |> visible()

    # MT-WARM now has content too → promotes to ⚪.
    primed_with_content =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{
            "MT-WARM" => %{attach_count: 1, visible_in: 2},
            "MT-OPEN" => %{attach_count: 1, visible_in: 1}
          },
          agents_with_content: MapSet.new(["MT-WARM", "MT-OPEN"]),
          opened_panes: MapSet.new(["MT-OPEN"])
        })
      )
      |> visible()

    assert hourglass =~ "⏳"
    refute hourglass =~ "🟢"

    # MT-WARM: pane painted, no content → 🔘
    # MT-OPEN: pane open in window 0 → 🟢
    assert primed_empty =~ "🔘"
    assert primed_empty =~ "🟢"

    # MT-WARM: pane painted AND has content → ⚪
    # MT-OPEN: still 🟢 (open in window 0)
    assert primed_with_content =~ "⚪"
    assert primed_with_content =~ "🟢"
    refute primed_with_content =~ "🔘"
  end

  test "active workflow phase overrides the warm marker with its emoji (#68)" do
    summaries = [
      %{identifier: "MT-PH", status: :running, alert_count: 0, work_state: :working}
    ]

    warm = %{
      summaries: summaries,
      attach_state: %{"MT-PH" => %{attach_count: 1, visible_in: 1}},
      agents_with_content: MapSet.new(["MT-PH"])
    }

    for {phase, emoji} <- [brainstorm: "🧠", plan: "📋", work: "🛠️", review: "🔍"] do
      out =
        render(base_state(Map.put(warm, :phase_by_identifier, %{"MT-PH" => phase})))
        |> visible()

      assert out =~ emoji, "expected #{phase} to render #{emoji}"
      # Phase replaces the ⚪ warm marker this agent would otherwise show.
      refute out =~ "⚪", "phase emoji should replace the warm marker for #{phase}"
    end
  end

  test "pre-warm ⏳ wins over an active phase while the pane isn't warm (#68)" do
    summaries = [
      %{identifier: "MT-COLD", status: :running, alert_count: 0, work_state: :working}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{},
          phase_by_identifier: %{"MT-COLD" => :work}
        })
      )
      |> visible()

    assert out =~ "⏳"
    refute out =~ "🛠️"
  end

  test "warm agent with no active phase falls back to its marker (#68)" do
    summaries = [
      %{identifier: "MT-NP", status: :running, alert_count: 0, work_state: :working}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{"MT-NP" => %{attach_count: 1, visible_in: 1}},
          agents_with_content: MapSet.new(["MT-NP"]),
          phase_by_identifier: %{}
        })
      )
      |> visible()

    assert out =~ "⚪"
  end

  test "help legend lists the phase palette (#68)" do
    out = render(base_state(%{help_visible?: true})) |> visible()

    assert out =~ "🧠"
    assert out =~ "📋"
    assert out =~ "🛠️"
    assert out =~ "🔍"
  end

  test "🔘 fires when slot painted but agent has not emitted content" do
    summaries = [
      %{identifier: "MT-A", status: :running, alert_count: 0, work_state: :working}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{"MT-A" => %{attach_count: 1, visible_in: 1}},
          agents_with_content: MapSet.new()
        })
      )
      |> visible()

    assert out =~ "🔘"
    refute out =~ "⚪"
  end

  test "⚪ requires both slot paint AND agent content; missing either yields a less-ready glyph" do
    summaries = [
      %{identifier: "MT-A", status: :running, alert_count: 0, work_state: :working}
    ]

    # Content but no slot paint → slow-open case → ⏳ (slot isn't
    # instant-open even though the agent is talking).
    no_paint =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{"MT-A" => %{attach_count: 1, visible_in: nil}},
          agents_with_content: MapSet.new(["MT-A"])
        })
      )
      |> visible()

    assert no_paint =~ "⏳"
    refute no_paint =~ "⚪"
  end

  test "warm-status row removed entirely (no ⬜️/🔲 glyphs in any render)" do
    summaries = [
      %{identifier: "MT-A", status: :running, alert_count: 0, work_state: :working}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          started_slots: MapSet.new([1, 2, 3]),
          fully_warmed_slots: MapSet.new([1])
        })
      )
      |> visible()

    refute out =~ "⬜️"
    refute out =~ "⬛️"
    refute out =~ "🔲"
    refute out =~ "🔳"
  end

  test "renders a runtime ticker (M:SS / H:MM:SS) from runtime_seconds" do
    summaries = [
      %{
        identifier: "MT-A",
        status: :running,
        alert_count: 0,
        runtime_seconds: 125,
        turn_count: 3
      }
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()

    assert out =~ "2:05"
    refute out =~ "AGE", "AGE column should be gone"
    refute out =~ "/3t", "turn-count suffix should be gone with the AGE column"
  end

  test "runtime ticker formats hour-scale runs as H:MM:SS" do
    summaries = [
      %{identifier: "MT-A", status: :running, alert_count: 0, runtime_seconds: 3725}
    ]

    out = render(base_state(%{summaries: summaries})) |> visible()
    assert out =~ "1:02:05"
  end

  test "title column flexes to fill the remaining width" do
    summaries = [
      %{
        identifier: "MT-A",
        status: :running,
        alert_count: 0,
        title: "A short title"
      }
    ]

    out = render(base_state(%{summaries: summaries, columns: 80})) |> visible()
    assert out =~ "A short title"
  end

  test "skips the screen clear escape so frames do not flash" do
    raw = render(base_state())
    # `\e[2J` is full-screen clear (causes flicker); `\e[J` is
    # clear-from-cursor-to-end (no flicker). We use the latter.
    refute raw =~ "\e[2J"
    assert raw =~ "\e[H"
  end

  test "clears every row below the last rendered content (no stale-footer bug)" do
    # A frame that renders fewer rows must leave the rows below it
    # blank. We assert the trailing escape sequence positions the
    # cursor exactly one row below the last content row and emits
    # `\e[J` to clear the rest of the screen.
    raw = render(base_state(%{rows: 30}))

    # Cursor home at the start.
    assert raw =~ "\e[H"
    # Some `\e[<N>;1H` cursor reset followed by `\e[J` clear-to-end.
    assert raw =~ ~r/\e\[\d+;1H\e\[J/
  end

  test "🟢 marker renders for the identifier whose pane is open in window 0" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0, work_state: :working},
      %{identifier: "MT-2", status: :running, alert_count: 0, work_state: :working}
    ]

    out =
      render(
        base_state(%{
          summaries: summaries,
          attach_state: %{
            "MT-1" => %{attach_count: 1, visible_in: 1},
            "MT-2" => %{attach_count: 1, visible_in: 2}
          },
          agents_with_content: MapSet.new(["MT-1", "MT-2"]),
          opened_panes: MapSet.new(["MT-1"])
        })
      )
      |> visible()

    lines = String.split(out, ["\r\n", "\n"])

    mt1_line = Enum.find(lines, fn line -> line =~ "MT-1" end)
    mt2_line = Enum.find(lines, fn line -> line =~ "MT-2" end)

    # MT-1's pane is open in window 0 → 🟢.
    # MT-2's leadoff slot has painted AND it has emitted content → ⚪.
    assert mt1_line =~ "🟢"
    refute mt2_line =~ "🟢"
    assert mt2_line =~ "⚪"
  end

  test "no 🟢 marker when nothing is visible" do
    summaries = [%{identifier: "MT-X", status: :running, alert_count: 0, work_state: :working}]
    out = render(base_state(%{summaries: summaries})) |> visible()

    refute out =~ "🟢"
  end

  test "footer shows v layout inline when terminal is wide enough" do
    out = render(base_state(%{columns: 100})) |> visible()

    assert out =~ "v layout"
    assert out =~ "? help"
    # All keybinds live on a single row when width allows.
    assert out =~ ~r/v layout\s+\? help\s+q quit/
  end

  test "footer wraps v layout to a second row when width is tight" do
    # 70-col terminal fits the original keybinds but not the version
    # that also includes "v layout". The primary row keeps the original
    # keybinds; "v layout" wraps below.
    out = render(base_state(%{columns: 70})) |> visible()
    lines = String.split(out, ["\r\n", "\n"])

    primary_index =
      Enum.find_index(lines, fn line ->
        line =~ "↑/↓ select" and line =~ "? help"
      end)

    assert primary_index, "expected primary keybind row to render"
    secondary = Enum.at(lines, primary_index + 1) || ""
    assert secondary =~ "v layout"
    refute Enum.at(lines, primary_index) =~ "v layout"
  end

  test "help overlay documents the v layout keybind" do
    out =
      render(base_state(%{help_visible?: true, columns: 100}))
      |> visible()

    assert out =~ "v"
    assert out =~ "toggle pane layout"
  end

  test "reserves the final terminal column to avoid autowrap" do
    long_id = String.duplicate("X", 200)
    summaries = [%{identifier: long_id, status: :running, alert_count: 0}]

    raw = render(base_state(%{summaries: summaries, columns: 30}))

    raw
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&visible/1)
    |> Enum.each(fn line ->
      assert String.length(line) <= 29, "line too long: #{inspect(line)}"
    end)
  end

  describe "❗ attention slot + Latest column (R5 / U21)" do
    # State column expands so the status emoji and the `❗` slot
    # render side by side. The slot is reserved blank space when no
    # attention is open, so layout doesn't jitter when state flips.
    test "renders status emoji + ❗ when an attention is open on the ticket" do
      summaries = [
        %{
          identifier: "MT-A",
          status: :running,
          alert_count: 0,
          work_state: :working
        }
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            attach_state: %{"MT-A" => %{attach_count: 1, visible_in: 1}},
            agents_with_content: MapSet.new(["MT-A"]),
            open_attentions_by_id: %{"MT-A" => 1},
            columns: 100
          })
        )
        |> visible()

      # ⚪ status emoji AND ❗ attention emoji both present on the row
      mt_a_line = Enum.find(String.split(out, ["\r\n", "\n"]), fn l -> l =~ "MT-A" end)
      assert mt_a_line, "expected to find MT-A row"
      assert mt_a_line =~ "⚪", "expected status emoji ⚪"
      assert mt_a_line =~ "❗", "expected attention emoji ❗"
    end

    test "renders ❗N when multiple attentions are open" do
      summaries = [
        %{identifier: "MT-B", status: :running, alert_count: 0, work_state: :working}
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            attach_state: %{"MT-B" => %{attach_count: 1, visible_in: 1}},
            agents_with_content: MapSet.new(["MT-B"]),
            open_attentions_by_id: %{"MT-B" => 3},
            columns: 100
          })
        )
        |> visible()

      assert out =~ "❗3"
    end

    test "reserves attention slot as blank when no attention is open (no jitter)" do
      # When attention count is zero, the row's *visual* width must
      # match the with-attention case so the Latest column doesn't
      # shift left/right when state flips. `String.length` is the
      # wrong metric here because `❗` is one code point but two
      # terminal columns — we measure visual width directly.
      summaries = [
        %{
          identifier: "MT-C",
          status: :running,
          alert_count: 0,
          work_state: :working,
          title: "a-title"
        }
      ]

      base = %{
        summaries: summaries,
        attach_state: %{"MT-C" => %{attach_count: 1, visible_in: 1}},
        agents_with_content: MapSet.new(["MT-C"]),
        columns: 100
      }

      without_attention =
        render(base_state(Map.put(base, :open_attentions_by_id, %{"MT-C" => 0}))) |> visible()

      with_attention =
        render(base_state(Map.put(base, :open_attentions_by_id, %{"MT-C" => 1}))) |> visible()

      [no_line | _] = Enum.filter(String.split(without_attention, ["\r\n", "\n"]), &(&1 =~ "MT-C"))
      [yes_line | _] = Enum.filter(String.split(with_attention, ["\r\n", "\n"]), &(&1 =~ "MT-C"))

      # Treat each emoji grapheme as 2 visual columns, everything else
      # as 1. Both rows should render to the same total visual width.
      visual_width = fn s ->
        s
        |> String.graphemes()
        |> Enum.map(fn g -> if byte_size(g) >= 3, do: 2, else: 1 end)
        |> Enum.sum()
      end

      assert visual_width.(no_line) == visual_width.(yes_line),
             "row visual width drifted when ❗ flipped:\n  no=#{inspect(no_line)}\n  yes=#{inspect(yes_line)}"
    end

    test "Latest column shows most recent event message for the ticket" do
      summaries = [
        %{identifier: "MT-D", status: :running, alert_count: 0, work_state: :working}
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            attach_state: %{"MT-D" => %{attach_count: 1, visible_in: 1}},
            agents_with_content: MapSet.new(["MT-D"]),
            latest_event_by_id: %{
              "MT-D" => %{
                topic: "ticket.MT-D.branch.push",
                message: "pushed abc1234",
                timestamp: DateTime.utc_now()
              }
            },
            columns: 120
          })
        )
        |> visible()

      assert out =~ "pushed abc1234", "expected Latest column to carry the event message"
    end

    test "Latest column is empty when no event has been seen for the ticket" do
      summaries = [
        %{identifier: "MT-E", status: :running, alert_count: 0, work_state: :working}
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            attach_state: %{"MT-E" => %{attach_count: 1, visible_in: 1}},
            agents_with_content: MapSet.new(["MT-E"]),
            latest_event_by_id: %{},
            columns: 120
          })
        )
        |> visible()

      mt_e_line = Enum.find(String.split(out, ["\r\n", "\n"]), &(&1 =~ "MT-E"))
      assert mt_e_line, "expected to find MT-E row"
      # No event content surfaces — but the row still renders cleanly.
    end
  end

  describe "progress column" do
    @ansi_green IO.ANSI.green()

    defp row_for(out, id) do
      Enum.find(String.split(out, ["\r\n", "\n"]), &(&1 =~ id))
    end

    test "mid-progress samples render the bar without the green tint" do
      summaries = [%{identifier: "MT-P", status: :running, alert_count: 0}]
      now_ms = System.monotonic_time(:millisecond)

      out =
        render(
          base_state(%{
            summaries: summaries,
            columns: 200,
            progress_by_id: %{"MT-P" => [{50, now_ms}]},
            now_ms: now_ms
          })
        )

      row = row_for(out, "MT-P")
      assert row, "expected MT-P row"
      assert visible(row) =~ "█████░░░░░"
      refute String.contains?(row, @ansi_green)
    end

    test "percent: 100 tints the bar green and fills all 10 cells" do
      summaries = [%{identifier: "MT-DONE", status: :running, alert_count: 0}]
      now_ms = System.monotonic_time(:millisecond)

      out =
        render(
          base_state(%{
            summaries: summaries,
            columns: 200,
            progress_by_id: %{"MT-DONE" => [{100, now_ms}]},
            now_ms: now_ms
          })
        )

      row = row_for(out, "MT-DONE")
      assert row, "expected MT-DONE row"
      assert visible(row) =~ "██████████"

      assert String.contains?(row, @ansi_green),
             "expected green ANSI wrap around the full bar at percent: 100"
    end

    test "rows without progress samples render an empty bar (no green)" do
      summaries = [%{identifier: "MT-IDLE", status: :running, alert_count: 0}]

      out =
        render(
          base_state(%{
            summaries: summaries,
            columns: 200,
            progress_by_id: %{}
          })
        )

      row = row_for(out, "MT-IDLE")
      assert row, "expected MT-IDLE row"
      assert visible(row) =~ "░░░░░░░░░░"
      refute String.contains?(row, @ansi_green)
    end
  end
end
