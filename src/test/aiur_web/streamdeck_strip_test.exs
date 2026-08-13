defmodule AiurWeb.StreamdeckStripTest do
  use ExUnit.Case, async: true

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
    assert message == %{shape: :message, speaker: :agent, text: "working"}
    assert tool == %{shape: :message, speaker: :tool, text: "mix test"}
    assert ci == %{shape: :message, speaker: :ci, text: "CI passed"}
    assert you == %{shape: :message, speaker: :you, text: "please continue"}
  end
end
