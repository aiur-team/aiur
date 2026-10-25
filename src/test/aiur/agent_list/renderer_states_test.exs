defmodule Aiur.AgentList.RendererStatesTest do
  use ExUnit.Case, async: true

  import Aiur.AgentListRendererSupport

  describe "deactivated / finished agents (#425)" do
    @ansi_green IO.ANSI.green()

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
