defmodule AiurWeb.StreamdeckStripTest do
  use ExUnit.Case, async: true

  alias AiurWeb.StreamdeckKeyFaceContract
  alias AiurWeb.StreamdeckStrip

  test "describes the focused command panel with the key progress hue" do
    command =
      StreamdeckStrip.command(%{
        identifier: "1582",
        vendor: "codex",
        title: "Render the logs strip",
        bucket: :running,
        progress_percent: 50
      })

    assert command == %{
             icon: "▶",
             number: "1582",
             provider: "codex",
             provider_logo: "/provider-assets/codex-color.svg",
             title: "Render the logs strip",
             status: "Running",
             accent: "#9fd0ff",
             percent: 50,
             progress_colour: "hsl(63 72% 50%)"
           }
  end

  test "agrees with the key face that unknown progress has no percentage and no hue" do
    command = StreamdeckStrip.command(%{identifier: "1582", bucket: :running, progress_percent: nil})

    assert command.percent == nil
    assert command.progress_colour == nil
  end

  test "keeps a stale-but-real percentage instead of reading it as zero" do
    command = StreamdeckStrip.command(%{identifier: "1582", bucket: :running, progress_percent: 70})

    assert command.percent == 70
    assert command.progress_colour == StreamdeckKeyFaceContract.progress_color(70)
  end

  test "rounds a float percentage rather than dropping it" do
    assert StreamdeckStrip.command(%{identifier: "1582", bucket: :running, progress_percent: 70.5}).percent == 71
  end

  test "an absent progress key reads as unknown, not as no progress" do
    assert StreamdeckStrip.command(%{identifier: "1582", bucket: :running}).percent == nil
  end

  test "every bucket takes its own accent and wording from the key-face contract" do
    for {bucket, accent, label} <- [
          {:alert, "#ffcf87", "Needs input"},
          {:stuck, "#ff9a90", "Stuck"},
          {:running, "#9fd0ff", "Running"},
          {:paused, "#c2c6cf", "Paused"},
          {:queued, "#9096a4", "Unstarted"}
        ] do
      command = StreamdeckStrip.command(%{identifier: "1", bucket: bucket, progress_percent: 0})

      assert command.accent == accent
      assert command.status == label
    end
  end

  test "an unknown bucket fails closed rather than rendering a default colour" do
    assert_raise ArgumentError, fn ->
      StreamdeckStrip.command(%{identifier: "1", bucket: :retired, progress_percent: 0})
    end
  end

  test "uses stable-width hint state at both bounds and in the middle" do
    assert StreamdeckStrip.hint(0, 3, "BACK") == %{label: "BACK", older?: false, newer?: true}
    assert StreamdeckStrip.hint(2, 3, "EVENTS") == %{label: "EVENTS", older?: true, newer?: true}
    assert StreamdeckStrip.hint(3, 3, "BACK") == %{label: "BACK", older?: true, newer?: false}
  end

  test "maps each flattened transcript entry to its strip shape" do
    [header, diff, addition, deletion, message, tool, ci, you] =
      StreamdeckStrip.entries([
        %{kind: :event_header, badge: "EMIT", body: "tool finished", timestamp: "not-a-time"},
        %{kind: :diff, path: "lib/strip.ex", additions: 0, deletions: 0, line: " context"},
        %{kind: :diff, path: "lib/strip.ex", additions: 2, deletions: 1, line: "added"},
        %{kind: :diff, path: "lib/strip.ex", additions: 0, deletions: 1, line: "removed"},
        %{kind: :message, role: "assistant", body: "working"},
        %{kind: :message, role: "tool", body: "mix test"},
        %{kind: :message, role: "system", body: "CI passed"},
        %{kind: :message, role: "user", body: "please continue"}
      ])

    assert header == %{
             shape: :evhdr,
             direction: "EMIT",
             colour: "#9fd0ff",
             text: "tool finished",
             time: "not-a-time"
           }

    assert %{shape: :diff, file: "lib/strip.ex", additions: 0, deletions: 0, line_kind: :context} = diff
    assert %{shape: :diff, line: "+added", line_kind: :addition} = addition
    assert %{shape: :diff, line: "-removed", line_kind: :deletion} = deletion
    # #1960: the speaker label is gone — the strip carries the row class (which
    # drives the per-kind colour) and the glyph gutter instead. Prose rows have
    # no glyph; tool rows take the `⚙` fallback when the body carries no
    # `read `/`write `/`edit ` prefix.
    assert message == %{shape: :message, kind: :agent, glyph: nil, text: "working"}
    assert tool == %{shape: :message, kind: :command, glyph: "⚙", text: "mix test"}
    assert ci == %{shape: :message, kind: :logs, glyph: nil, text: "CI passed"}
    assert you == %{shape: :message, kind: :user, glyph: nil, text: "please continue"}
  end

  # The feed unrolls a hunk into one row per line. Without a clause of its own
  # every one of those rows fell to the catch-all and painted as an empty `:ci`
  # message, so a diff on the strip was a header followed by blank rows.
  test "maps an unrolled hunk line to its own shape, keeping its sign" do
    assert StreamdeckStrip.entries([
             %{kind: :diff_line, sign: "+", text: "  added()"},
             %{kind: :diff_line, sign: "-", text: "  removed()"},
             %{kind: :diff_line, sign: " ", text: "  context()"}
           ]) == [
             %{shape: :diff_line, line: "+  added()", line_kind: :addition},
             %{shape: :diff_line, line: "-  removed()", line_kind: :deletion},
             %{shape: :diff_line, line: "   context()", line_kind: :context}
           ]
  end
end
