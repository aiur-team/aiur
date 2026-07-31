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
        agent_kind: nil,
        agent_count: nil,
        max_agents: nil
      },
      overrides
    )
  end

  test "renders the bordered AIUR title without a refresh chip" do
    out = render(base_state()) |> visible()

    assert out =~ "╭─ AIUR"
    assert out =~ "╰"
    refute out =~ "🔄"
  end

  test "renders the metadata block with project and dashboard" do
    out =
      render(
        base_state(%{
          project_label: "applekid/aiur",
          dashboard_url: "http://127.0.0.1:4000/"
        })
      )
      |> visible()

    assert out =~ "Project:"
    assert out =~ "applekid/aiur"
    assert out =~ "Dashboard:"
    assert out =~ "http://127.0.0.1:4000/"
  end

  test "falls back to n/a placeholders when metadata is missing" do
    out = render(base_state()) |> visible()

    assert out =~ "Agents: n/a"
    assert out =~ "Project: n/a"
    assert out =~ "Dashboard: n/a"
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
    assert out =~ "Agents: 2/5"
  end

  test "marks the max display as draining when active exceeds max" do
    out =
      render(
        base_state(%{
          summaries: [
            %{identifier: "MT-1", status: :running, alert_count: 0},
            %{identifier: "MT-2", status: :running, alert_count: 0},
            %{identifier: "MT-3", status: :running, alert_count: 0},
            %{identifier: "MT-4", status: :running, alert_count: 0}
          ],
          agent_kind: "codex",
          agent_count: 4,
          max_agents: 3
        })
      )
      |> visible()

    assert out =~ "Agents: 4/3 drain"
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

    assert out =~ "Agents: 1/[2]"
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
    # order is ID → tag-circle → state-circle → MODEL → TITLE →
    # LATEST → PROGRESS → TIME.
    assert out =~ ~r/ID\s+MODEL\s+TITLE\s+LATEST\s+PROGRESS\s+TIME/
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

  test "selected row uses a theme-aware reverse highlight, not a hardcoded background" do
    summaries = [
      %{identifier: "MT-1", status: :running, alert_count: 0},
      %{identifier: "MT-2", status: :running, alert_count: 0}
    ]

    raw = render(base_state(%{summaries: summaries, selection_index: 1}))

    # The selected row inverts via the terminal standout attribute so it
    # stays legible on both dark and light terminal themes.
    assert raw =~ IO.ANSI.reverse()
    # No hardcoded 256-color background that assumes a dark terminal.
    refute raw =~ "\e[48;5;236m"
  end

  describe "ID column OSC 8 ticket hyperlink (#414)" do
    # `id_cell_with_link/2` reads :project_label from the layout map, which
    # render/1 must thread in from state. These tests guard against the
    # regression where project_label lived only on state and the link was
    # silently dead in every live render.
    @issue_link "\e]8;;https://github.com/its-everdred/aiur/issues/414\e\\"

    test "wraps a numeric identifier in an OSC 8 link to its GitHub issue" do
      summaries = [%{identifier: "414", status: :running, alert_count: 0}]

      raw =
        render(base_state(%{summaries: summaries, project_label: "its-everdred/aiur"}))

      assert raw =~ @issue_link
    end

    test "preserves the ticket link on the selected row" do
      summaries = [%{identifier: "414", status: :running, alert_count: 0}]

      raw =
        render(
          base_state(%{
            summaries: summaries,
            selection_index: 0,
            project_label: "its-everdred/aiur"
          })
        )

      # The selected row is inverted and stripped of CSI color, but OSC 8
      # hyperlinks must survive so the link stays clickable when highlighted.
      assert raw =~ IO.ANSI.reverse()
      assert raw =~ @issue_link
    end

    test "emits no link when the project is unknown" do
      summaries = [%{identifier: "414", status: :running, alert_count: 0}]

      raw = render(base_state(%{summaries: summaries, project_label: nil}))

      refute raw =~ "\e]8;;"
    end

    test "emits no link for a non-numeric identifier" do
      summaries = [%{identifier: "MT-1", status: :running, alert_count: 0}]

      raw =
        render(base_state(%{summaries: summaries, project_label: "its-everdred/aiur"}))

      refute raw =~ "\e]8;;"
    end
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

    assert out =~ "Agents: 1/[2]"
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

    for {phase, emoji} <- [brainstorm: "🧠", plan: "📋", work: "🔨", review: "🔍"] do
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
    refute out =~ "🔨"
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
    assert out =~ "🔨"
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

  describe "Starting-phase placeholder names the agent's own engine" do
    defp starting_state(backend) do
      summary = %{identifier: "MT-S", status: :running, alert_count: 0, work_state: :working}
      summary = if backend, do: Map.put(summary, :backend, backend), else: summary

      base_state(%{
        columns: 200,
        summaries: [summary],
        attach_state: %{"MT-S" => %{attach_count: 1, visible_in: 1}},
        agents_with_content: MapSet.new()
      })
    end

    test "a claude-repl agent reads Starting claude, never codex" do
      out = render(starting_state("claude-repl")) |> visible()

      assert out =~ "Starting claude…"
      refute out =~ "codex"
    end

    test "a codex agent reads Starting codex" do
      out = render(starting_state("codex")) |> visible()

      assert out =~ "Starting codex…"
    end

    test "an unknown backend falls back to a generic Starting…" do
      out = render(starting_state(nil)) |> visible()

      assert out =~ "Starting…"
      refute out =~ "codex"
    end
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

  test "wraps the frame in a synchronized update so partial frames never paint" do
    # DEC 2026 begin/end: a slow consumer otherwise renders a partial
    # frame, splitting multi-byte glyphs into transient `?` replacement
    # characters (the agent-list "??????" flicker during initial load).
    raw = render(base_state())
    assert String.starts_with?(raw, "\e[?2026h")
    assert String.ends_with?(raw, "\e[?2026l")
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
      # MT-DONE is rendered unselected (selection sits on MT-OTHER) so the
      # green tint is asserted in isolation: the selected row flattens
      # interior colors into its `reverse` highlight (see the theme-aware
      # selection test above), which would otherwise strip this green.
      summaries = [
        %{identifier: "MT-DONE", status: :running, alert_count: 0},
        %{identifier: "MT-OTHER", status: :running, alert_count: 0}
      ]

      now_ms = System.monotonic_time(:millisecond)

      out =
        render(
          base_state(%{
            summaries: summaries,
            selection_index: 1,
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

    test "rows without progress samples render an intentional empty track, not a hatched bar" do
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
      # A full row of ░ reads as a corrupt/half-filled bar (#425). With no
      # samples we render a faint dotted track instead so the empty state
      # is unambiguous.
      assert visible(row) =~ "··········"
      refute visible(row) =~ "░", "no-sample state must not render the hatched ░ bar"
      refute String.contains?(row, @ansi_green)
    end
  end

  describe "deactivated / finished agents (#425)" do
    # Every member of the renderer's finished-work-state set should reach
    # 🏁 and never the warming ⏳ — both atom and string encodings, and
    # both :deactivated and :done. Parametrized so dropping any member
    # from the constant (or breaking a string variant) fails a test.
    for work_state <- [:deactivated, "deactivated", :done, "done"] do
      test "a finished agent (work_state=#{inspect(work_state)}) renders 🏁, not the warming ⏳ marker" do
        summaries = [
          %{identifier: "MT-FIN", status: :running, alert_count: 0, work_state: unquote(work_state)}
        ]

        out =
          render(base_state(%{summaries: summaries, columns: 200}))
          |> visible()

        row = Enum.find(String.split(out, ["\r\n", "\n"]), &(&1 =~ "MT-FIN"))
        assert row, "expected MT-FIN row"
        assert row =~ "🏁", "finished agent should reach 🏁"
        refute row =~ "⏳", "finished agent must not show the warming hourglass"
      end
    end

    test "a seeded deactivated agent shows 🏁 + green 100% bar + blank LATEST together" do
      # The real production row for a finished agent: app.ex seeds a 100%
      # progress sample on deactivation, so the row paints 🏁, a green
      # full bar, and (with no latest event) an empty LATEST — the exact
      # acceptance state from #425. MT-OTHER holds the selection so the
      # green tint on MT-FIN isn't flattened by the reverse highlight.
      now_ms = System.monotonic_time(:millisecond)

      summaries = [
        %{identifier: "MT-FIN", status: :running, alert_count: 0, work_state: :deactivated, title: "shipped"},
        %{identifier: "MT-OTHER", status: :running, alert_count: 0, work_state: :working}
      ]

      raw =
        render(
          base_state(%{
            summaries: summaries,
            selection_index: 1,
            columns: 200,
            progress_by_id: %{"MT-FIN" => [{100, now_ms}]},
            latest_event_by_id: %{},
            now_ms: now_ms
          })
        )

      row = Enum.find(String.split(raw, ["\r\n", "\n"]), &(&1 =~ "MT-FIN"))
      assert row, "expected MT-FIN row"
      assert visible(row) =~ "🏁"
      assert visible(row) =~ "██████████", "deactivated agent should show the full 100% bar"
      assert String.contains?(row, @ansi_green), "the 100% bar should be tinted green"
      refute visible(row) =~ "Warming up", "finished row must not show the warming placeholder"
    end

    test "a deactivated agent that still has a latest event shows the event, not a blank LATEST" do
      # The placeholder suppression must only replace the warming/starting
      # placeholder — never swallow a real final message. latest_cell only
      # falls back to the placeholder when there is no latest event, so a
      # deactivated agent with an event must still render it.
      summaries = [
        %{identifier: "MT-MSG", status: :running, alert_count: 0, work_state: :deactivated, title: "done"}
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            columns: 200,
            latest_event_by_id: %{"MT-MSG" => %{message: "pushed PR 421"}}
          })
        )
        |> visible()

      row = Enum.find(String.split(out, ["\r\n", "\n"]), &(&1 =~ "MT-MSG"))
      assert row, "expected MT-MSG row"
      assert row =~ "pushed PR 421", "deactivated agent's real latest event must still render"
    end

    test "a deactivated agent with a detached slot does not show 'Warming up…'" do
      # A finished agent has its slot released, so attach_state is empty
      # and there is no latest event — the LATEST column previously fell
      # back to a frozen 'Warming up…' placeholder (#425).
      summaries = [
        %{
          identifier: "MT-DET",
          status: :running,
          alert_count: 0,
          work_state: :deactivated,
          title: "finished work"
        }
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            columns: 200,
            attach_state: %{},
            latest_event_by_id: %{}
          })
        )
        |> visible()

      row = Enum.find(String.split(out, ["\r\n", "\n"]), &(&1 =~ "MT-DET"))
      assert row, "expected MT-DET row"
      refute row =~ "Warming up", "a finished agent must not be stuck in the warming placeholder"
      refute row =~ "Starting", "a finished agent must not show a starting placeholder"
    end
  end

  describe "remote-control indicator (U5)" do
    defp rc_row(out, id), do: Enum.find(String.split(out, ["\r\n", "\n"]), &(&1 =~ id))

    test ":on shows 📱, :launching shows 📲, :failed shows ❌, :off shows none" do
      summaries = [
        %{identifier: "RC-ON", status: :running, alert_count: 0, remote_control: %{status: :on}},
        %{identifier: "RC-LCH", status: :running, alert_count: 0, remote_control: %{status: :launching}},
        %{identifier: "RC-FAIL", status: :running, alert_count: 0, remote_control: %{status: :failed}},
        %{identifier: "RC-OFF", status: :running, alert_count: 0}
      ]

      out = render(base_state(%{summaries: summaries, columns: 200}))

      assert visible(rc_row(out, "RC-ON")) =~ "📱"
      assert visible(rc_row(out, "RC-LCH")) =~ "📲"
      assert visible(rc_row(out, "RC-FAIL")) =~ "❌"

      # RC-OFF carries no RC glyph (it still shows the ⏳ warming
      # state marker, which is a separate column — hence we only
      # refute the RC glyphs here).
      off = visible(rc_row(out, "RC-OFF"))
      refute off =~ "📱"
      refute off =~ "📲"
      refute off =~ "❌"
    end

    test "indicator column keeps alignment across statuses (no crash, right border intact)" do
      summaries = [
        %{identifier: "RC-ON", status: :running, alert_count: 0, remote_control: %{status: :on}},
        %{identifier: "RC-OFF", status: :running, alert_count: 0}
      ]

      out = render(base_state(%{summaries: summaries, columns: 200}))

      # Each agent row closes with the right `│` border regardless of
      # whether the RC glyph is present (fixed indicator width).
      on_row = visible(rc_row(out, "RC-ON"))
      off_row = visible(rc_row(out, "RC-OFF"))
      assert String.ends_with?(String.trim_trailing(on_row), "│")
      assert String.ends_with?(String.trim_trailing(off_row), "│")
    end

    test "an RC-on agent's session URL is kept OFF the footer (it rides the pane border now)" do
      # The capability-token URL moved to the chat-pane top border (set via
      # tmux in Aiur.AgentList.App) so it travels with the pane it belongs
      # to. The agent-list footer must no longer surface it.
      url = "https://claude.ai/code/session_01ABC"

      summaries = [
        %{
          identifier: "RC-URL",
          status: :running,
          alert_count: 0,
          remote_control: %{status: :on, session_url: url}
        }
      ]

      out =
        render(
          base_state(%{
            summaries: summaries,
            columns: 200,
            selection_index: 0,
            selection_focus: :agents
          })
        )
        |> visible()

      refute out =~ url
    end

    test "a transient hint is shown on the footer line" do
      out =
        render(base_state(%{remote_control_hint: "Remote Control requires a local Claude agent"}))
        |> visible()

      assert out =~ "Remote Control requires a local Claude agent"
    end
  end

  describe "MODEL column (mirrors the website Example column)" do
    defp model_summary(overrides) do
      Map.merge(
        %{identifier: "MT-1", status: :running, alert_count: 0, work_state: :working},
        overrides
      )
    end

    test "wide terminal shows the full version suffix per model" do
      for {backend, model, full} <- [
            {"claude-repl", "opus-4-8", "Claude Opus 4.8"},
            {"claude-repl", "sonnet-4-6", "Claude Sonnet 4.6"},
            {"codex", "gpt-5.5", "Codex GPT-5.5"}
          ] do
        out =
          render(
            base_state(%{
              summaries: [model_summary(%{backend: backend, model: model, title: "Short"})],
              columns: 200
            })
          )
          |> visible()

        assert out =~ full, "expected #{full} at wide width for #{backend}/#{model}"
      end
    end

    test "medium terminal shows the base name only, version suffix dropped" do
      out =
        render(
          base_state(%{
            summaries: [
              model_summary(%{backend: "claude-repl", model: "opus-4-8", title: "Short"})
            ],
            latest_event_by_id: %{"MT-1" => %{message: "Working on it"}},
            columns: 90
          })
        )
        |> visible()

      # The base name persists; the version suffix yields *before* LATEST or
      # TITLE — both of which still render in full at this width.
      assert out =~ "Opus"
      refute out =~ "Claude Opus 4.8"
      assert out =~ "Short", "TITLE kept its width when the version dropped"
      assert out =~ "Working on it", "LATEST kept its width when the version dropped"
    end

    test "extreme narrowness drops the whole MODEL column" do
      out =
        render(
          base_state(%{
            summaries: [model_summary(%{backend: "codex", model: "gpt-5.5", title: "Short"})],
            columns: 40
          })
        )
        |> visible()

      refute out =~ "MODEL", "MODEL header should drop at extreme narrowness"
      refute out =~ "Codex", "MODEL cell should drop at extreme narrowness"
    end

    test "uses 24-bit truecolor escapes per model on truecolor terminals" do
      for {backend, model, hex, text} <- [
            {"claude-repl", "opus-4-8", "\e[38;2;198;155;255m", "Claude Opus 4.8"},
            {"claude-repl", "sonnet-4-6", "\e[38;2;89;176;255m", "Claude Sonnet 4.6"},
            {"codex", "gpt-5.5", "\e[38;2;63;185;80m", "Codex GPT-5.5"}
          ] do
        raw =
          render(
            base_state(%{
              summaries: [model_summary(%{backend: backend, model: model, title: "Short"})],
              columns: 200,
              truecolor?: true,
              # Keep the row unselected — selected rows strip interior SGRs.
              selection_focus: :max_agents
            })
          )

        assert raw =~ hex <> text, "expected truecolor #{inspect(hex)} before #{text}"
      end
    end

    test "falls back to ANSI colors without truecolor support" do
      for {backend, model, ansi, text} <- [
            {"claude-repl", "opus-4-8", IO.ANSI.magenta(), "Claude Opus 4.8"},
            {"claude-repl", "sonnet-4-6", IO.ANSI.blue(), "Claude Sonnet 4.6"},
            {"codex", "gpt-5.5", IO.ANSI.green(), "Codex GPT-5.5"}
          ] do
        raw =
          render(
            base_state(%{
              summaries: [model_summary(%{backend: backend, model: model, title: "Short"})],
              columns: 200,
              truecolor?: false,
              # Keep the row unselected — selected rows strip interior SGRs.
              selection_focus: :max_agents
            })
          )

        assert raw =~ ansi <> text, "expected ANSI #{inspect(ansi)} before #{text}"
      end
    end

    test "queued agents render a dim placeholder with no model" do
      out =
        render(
          base_state(%{
            summaries: [%{identifier: "MT-9", status: :queued, alert_count: 0, title: "Pending"}],
            columns: 200
          })
        )
        |> visible()

      assert out =~ "–", "queued row should show the en-dash placeholder"
    end

    test "unpinned models show the base name with no version suffix" do
      out =
        render(
          base_state(%{
            summaries: [model_summary(%{backend: "codex", title: "Short"})],
            columns: 200
          })
        )
        |> visible()

      assert out =~ "Codex"
      refute out =~ "GPT", "an unpinned model must not show a version suffix"
    end

    test "renders a mix of queued, unpinned, and pinned rows without error" do
      summaries = [
        %{identifier: "Q-1", status: :queued, alert_count: 0, title: "Queued"},
        model_summary(%{identifier: "U-1", backend: "claude-repl", title: "Unpinned"}),
        model_summary(%{identifier: "P-1", backend: "codex", model: "gpt-5.5", title: "Pinned"})
      ]

      out = render(base_state(%{summaries: summaries, columns: 200})) |> visible()

      assert out =~ "–"
      assert out =~ "Claude"
      assert out =~ "Codex GPT-5.5"
    end
  end
end
