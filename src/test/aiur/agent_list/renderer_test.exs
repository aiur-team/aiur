defmodule Aiur.AgentList.RendererTest do
  use ExUnit.Case, async: true

  import Aiur.AgentListRendererSupport

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
end
