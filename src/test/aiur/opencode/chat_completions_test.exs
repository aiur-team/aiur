defmodule Aiur.Opencode.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ChatCompletions

  test "build_chunk returns an OpenAI-compatible streaming envelope" do
    chunk = ChatCompletions.build_chunk("chatcmpl-test", %{content: "hello", finish_reason: nil})

    assert chunk.id == "chatcmpl-test"
    assert chunk.object == "chat.completion.chunk"
    assert [%{delta: %{content: "hello"}, finish_reason: nil}] = chunk.choices
  end

  test "build_chunk omits delta content for final chunks" do
    chunk = ChatCompletions.build_chunk("chatcmpl-test", %{content: nil, finish_reason: "stop"})

    assert [%{delta: %{}, finish_reason: "stop"}] = chunk.choices
  end

  describe "format_delta/2" do
    test ":command renders as a blockquote with inline-code body" do
      # Wrapping the command body in backticks lets glamour apply
      # the theme's `markdownCode` color (darkStep11 grey)
      # independently from blockquote bar color (BlockQuote only
      # colors the bar, not the text inside). The `$ ` prefix
      # stays OUTSIDE the code span so it renders in default
      # color, not as code.
      out = ChatCompletions.format_delta(:command, "git status --short")
      assert out == "\n> $ `git status --short`\n"
    end

    test ":command with multi-line body falls back to bar-only blockquote" do
      # Inline code spans don't wrap across newlines, so heredoc-style
      # multi-line commands can't ride the inline-code dim path. The
      # bar-on-every-line treatment via Style.dim keeps them visually
      # grouped even if their text doesn't carry the inline-code color.
      heredoc = "gh issue comment 101 --body-file - <<'EOF'\nfirst\nsecond\nEOF"
      out = ChatCompletions.format_delta(:command, heredoc)

      assert String.starts_with?(out, "\n> $ gh issue comment")
      assert String.contains?(out, "\n> first\n")
      assert String.contains?(out, "\n> second\n")
      assert String.contains?(out, "\n> EOF\n")
    end

    test ":command with backticks in body falls back to bar-only blockquote" do
      # Real-world case: `gh issue comment 99 --body $'…```text…'`
      # carries literal backticks inside a `$'...'` heredoc. Wrapping
      # such a body in inline-code would close the span mid-content
      # and the rest renders in normal-color, breaking the dim
      # styling halfway through. Detect backticks and route to the
      # bar-only blockquote where Style.dim handles them safely.
      body = ~s(gh issue comment 99 --body $'```text\\nfoo\\n```')
      out = ChatCompletions.format_delta(:command, body)

      # The bar-only path doesn't wrap with `> $ \`…\`` syntax —
      # check the absence of that specific pattern. Backticks
      # in the body itself are allowed to pass through as text.
      refute String.starts_with?(out, "\n> $ `"),
             "must not wrap backtick-containing body in inline code"

      assert String.contains?(out, "> $ gh issue comment 99")
    end

    test ":command normalizes literal `\\n` to real newlines so heredocs render multi-row" do
      # When codex's transcript captures a `$'…\\n…'` heredoc, the
      # command string contains a literal backslash-n pair rather
      # than a real newline. The bridge converts those so the chat
      # pane shows the heredoc body on multiple rows instead of
      # printing the escape glyphs.
      body = "gh issue comment 99 --body $'## Header\\nfirst line\\nsecond'"
      out = ChatCompletions.format_delta(:command, body)

      refute String.contains?(out, "\\n"), "literal `\\n` should be converted to real newlines"
      assert String.contains?(out, "first line")
      assert String.contains?(out, "second")
    end

    test ":tool with 'edit <path>' body renders as a file-edit blockquote with inline-code path" do
      out = ChatCompletions.format_delta(:tool, "edit lib/foo.ex")
      assert out == "\n> ✏️  `edit lib/foo.ex`\n"
    end

    test ":tool 'edit' with a diff payload appends a ```diff fenced block" do
      # R4: when the codex transcript carries the file-change diff
      # (Aiur.Codex.Transcript.build_tool_payload/2 stuffs it in
      # `payload.output`), the bridge surfaces the diff hunks as a
      # fenced `diff` block so glamour renders +/- with color.
      diff = """
      @@ -1,3 +1,4 @@
       hello
      -world
      +world!
      +new line
      """

      event = %{
        role: :tool,
        body: "edit lib/foo.ex",
        payload: %{tool: "edit", output: diff}
      }

      out = ChatCompletions.format_delta(:tool, "edit lib/foo.ex", event)

      assert String.starts_with?(out, "\n> ✏️  `edit lib/foo.ex`\n")
      assert out =~ "```diff"
      assert out =~ "+world!"
      assert out =~ "-world"
    end

    test ":tool 'edit' without a diff payload falls back to summary-only" do
      out = ChatCompletions.format_delta(:tool, "edit lib/foo.ex", %{})
      # Emoji + space stays outside the code span; only the file
      # path + verb ride inline code so glamour can paint them dim.
      assert out == "\n> ✏️  `edit lib/foo.ex`\n"
    end

    test ":tool 'edit' with whole-file content (no diff markers) gets + prefixes" do
      # When codex creates a new file or whole-file-replaces, it
      # emits the full new content without `@@`/`+`/`-` markers.
      # The bridge prefixes every line with `+ ` so glamour's
      # ```diff renderer paints them green.
      new_file = """
      defmodule Hello do
        def world, do: :ok
      end
      """

      event = %{
        role: :tool,
        body: "edit lib/hello.ex",
        payload: %{tool: "edit", output: new_file}
      }

      out = ChatCompletions.format_delta(:tool, "edit lib/hello.ex", event)

      assert out =~ "```diff"
      assert out =~ "+ defmodule Hello do"
      assert out =~ "+   def world, do: :ok"
      assert out =~ "+ end"
    end

    test ":tool with 'read <path>' body renders as a file-read blockquote" do
      out = ChatCompletions.format_delta(:tool, "read lib/foo.ex")
      assert out == "\n> 📖 `read lib/foo.ex`\n"
    end

    test ":tool with a non-file-op title falls back to a dim inline-code blockquote" do
      out = ChatCompletions.format_delta(:tool, "emit_alert")
      assert out == "\n> → `emit_alert`\n"
    end

    test ":reasoning renders as markdown italic" do
      out = ChatCompletions.format_delta(:reasoning, "thinking…")
      assert out == "\n_thinking…_\n"
    end

    test ":alert renders as a blockquote with bell emoji" do
      out = ChatCompletions.format_delta(:alert, "awaiting approval")
      assert out == "\n> 🔔 awaiting approval\n"
    end

    test "unknown role passes the body through unchanged" do
      assert ChatCompletions.format_delta(:assistant, "hi") == "hi"
    end
  end

  describe "transcript_delta/2" do
    test "a remote-origin :user event drops — never streams as an assistant delta" do
      # Rendering the Remote Control message inline in the assistant SSE
      # made it read as agent speech. It must drop here and instead be
      # persisted as a genuine user-role message by SessionWriter.
      event = %{role: :user, body: "hi from the Remote Control app", payload: %{origin: :remote}}

      assert ChatCompletions.transcript_delta(event, nil) == :drop
      assert ChatCompletions.transcript_delta(event, :assistant) == :drop
    end

    test "an opencode-origin :user event (no remote payload) also drops" do
      assert ChatCompletions.transcript_delta(%{role: :user, body: "typed locally", payload: nil}, :assistant) ==
               :drop
    end

    test "an :assistant event streams its body verbatim as a delta" do
      assert ChatCompletions.transcript_delta(%{role: :assistant, body: "hello"}, nil) ==
               {:delta, "hello", :assistant}
    end

    test "a :command event streams as a dim blockquote delta" do
      assert ChatCompletions.transcript_delta(%{role: :command, body: "ls"}, nil) ==
               {:delta, "\n> $ `ls`\n", :command}
    end
  end

  describe "segment boundaries (segmented turn streams)" do
    test "a tool/command event past the threshold is a boundary" do
      assert ChatCompletions.segment_boundary?(:tool, 25_000, 20_000)
      assert ChatCompletions.segment_boundary?(:command, 20_000, 20_000)
    end

    test "below the threshold nothing is a boundary" do
      refute ChatCompletions.segment_boundary?(:tool, 19_999, 20_000)
    end

    test "assistant prose mid-thought is never a boundary" do
      refute ChatCompletions.segment_boundary?(:assistant, 120_000, 20_000)
      refute ChatCompletions.segment_boundary?(:reasoning, 120_000, 20_000)
    end

    test "idle boundary needs threshold age plus one heartbeat of silence" do
      assert ChatCompletions.idle_segment_boundary?(true, 3, 25_000, 16_000, 20_000, 15_000)
      refute ChatCompletions.idle_segment_boundary?(true, 3, 25_000, 5_000, 20_000, 15_000)
      refute ChatCompletions.idle_segment_boundary?(true, 3, 15_000, 16_000, 20_000, 15_000)
    end

    test "an empty continuation segment idle-closes after a longer silence (flush, bounded churn)" do
      # One heartbeat of silence is enough for a streamed segment, but an empty
      # continuation waits @empty_continuation_idle_factor (2) heartbeats so a
      # slow quiet tool run doesn't churn a marker every heartbeat.
      refute ChatCompletions.idle_segment_boundary?(false, 2, 120_000, 16_000, 20_000, 15_000)
      # After two heartbeats of silence it flushes queued operator input.
      assert ChatCompletions.idle_segment_boundary?(false, 2, 120_000, 31_000, 20_000, 15_000)
    end

    test "the empty turn-opening segment may idle-close (quiet turn start)" do
      assert ChatCompletions.idle_segment_boundary?(false, 0, 25_000, 16_000, 20_000, 15_000)
    end
  end

  describe "watchdog_action/2 (inactivity watchdog)" do
    test "closes once silence reaches the watchdog window" do
      assert {:close, 600_000} = ChatCompletions.watchdog_action(600_000, 600_000)
      assert {:close, 600_001} = ChatCompletions.watchdog_action(600_001, 600_000)
    end

    test "reschedules for the remaining window while activity is recent (no false close)" do
      # The timer fires 10 min after arming, but an actively-streaming turn
      # keeps bumping last_event_at — so measured silence is short and the
      # watchdog must reschedule for exactly the remaining window, never close.
      assert {:reschedule, 420_000} = ChatCompletions.watchdog_action(180_000, 600_000)
      assert {:reschedule, 600_000} = ChatCompletions.watchdog_action(0, 600_000)
    end

    test "the reschedule delay is always strictly positive (no zero/negative send_after)" do
      for silent <- [0, 1, 599_999] do
        assert {:reschedule, delay} = ChatCompletions.watchdog_action(silent, 600_000)
        assert delay > 0
      end
    end
  end

  describe "trailing_user_texts/1 (coalescing defenses)" do
    test "collects only the user run since the last assistant message" do
      body = %{
        "messages" => [
          %{"role" => "user", "content" => "old question"},
          %{"role" => "assistant", "content" => "old answer"},
          %{"role" => "user", "content" => "fix the tests"},
          %{"role" => "user", "content" => "__aiur_turn__:t1abc-s2"}
        ]
      }

      assert ChatCompletions.trailing_user_texts(body) == [
               "fix the tests",
               "__aiur_turn__:t1abc-s2"
             ]
    end

    test "parts-shaped content is flattened" do
      body = %{
        "messages" => [
          %{"role" => "assistant", "content" => "x"},
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}
        ]
      }

      assert ChatCompletions.trailing_user_texts(body) == ["hello"]
    end

    test "no trailing user run yields an empty list" do
      assert ChatCompletions.trailing_user_texts(%{"messages" => [%{"role" => "assistant", "content" => "x"}]}) ==
               []

      assert ChatCompletions.trailing_user_texts(%{}) == []
    end
  end

  describe "normalize_operator_text/1 (strip opencode <system-reminder> wrappers)" do
    test "mid-stream interjection form: extracts the raw operator message" do
      wrapped =
        "<system-reminder>\nThe user sent the following message:\n" <>
          "hi from opencode, pause and respond exactly \"123\"\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert ChatCompletions.normalize_operator_text(wrapped) ==
               "hi from opencode, pause and respond exactly \"123\""
    end

    test "idle form: strips the 'Message sent at' reminder, keeps the raw text" do
      wrapped = "<system-reminder>Message sent at Sun 2026-06-14 17:19:23 UTC.</system-reminder>\nhi from ce, respond exactly \"456\""

      assert ChatCompletions.normalize_operator_text(wrapped) == "hi from ce, respond exactly \"456\""
    end

    test "already-raw operator text passes through unchanged" do
      assert ChatCompletions.normalize_operator_text("just say banana") == "just say banana"
    end

    test "a reminder with no operator content normalizes to empty (dropped upstream)" do
      assert ChatCompletions.normalize_operator_text("<system-reminder>cwd changed to /tmp</system-reminder>") == ""
    end

    test "recovers the operator message when scaffolding reminders precede the wrapper" do
      # opencode prepends its own <system-reminder> scaffolding (cwd/goal/
      # files) to the payload, so the operator wrapper is no longer the whole
      # string. The old \A..\z-anchored match missed and the generic strip
      # deleted the operator-bearing block too -> "" -> silent drop ("never
      # answered"). Extraction must survive the surrounding scaffolding.
      payload =
        "<system-reminder>cwd changed to /tmp/work</system-reminder>\n" <>
          "<system-reminder>\nThe user sent the following message:\n" <>
          "pause and respond with exactly one word: BANANA\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert ChatCompletions.normalize_operator_text(payload) ==
               "pause and respond with exactly one word: BANANA"
    end

    test "recovers the operator message when a scaffolding reminder trails the wrapper" do
      payload =
        "<system-reminder>\nThe user sent the following message:\n" <>
          "respond exactly \"123\"\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>\n" <>
          "<system-reminder>goal: ship the PR</system-reminder>"

      assert ChatCompletions.normalize_operator_text(payload) == "respond exactly \"123\""
    end

    test "recovers every operator message when opencode folds several into one batch" do
      payload =
        "<system-reminder>\nThe user sent the following message:\nfirst\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>" <>
          "<system-reminder>\nThe user sent the following message:\nsecond\n\n" <>
          "Please address this message and continue with your tasks.\n</system-reminder>"

      assert ChatCompletions.normalize_operator_text(payload) == "first\nsecond"
    end

    test "never drops a present operator message to empty (silent-drop guard)" do
      # The core defect: an operator message that normalizes to "" is acked as
      # a noop (send_operator/3) and never reaches the agent. This is the
      # "never answered" + "QUEUED clears before read" double symptom.
      payload =
        "<system-reminder>selection: lib/foo.ex:1-3</system-reminder>\n" <>
          "<system-reminder>\nThe user sent the following message:\n" <>
          "say hello\n\nPlease address this message and continue with your tasks.\n</system-reminder>"

      refute ChatCompletions.normalize_operator_text(payload) == ""
      assert ChatCompletions.normalize_operator_text(payload) == "say hello"
    end
  end

  describe "finish_reason_for/1" do
    test ":input_required finishes with stop, not tool_calls" do
      # A "tool_calls" finish with no tool-call payload makes opencode
      # re-open the chat-completion request for the same unanswered
      # __aiur_turn__ marker, busy-looping until the ActiveTurns entry
      # expires (~60s) and pegging the TUI. "stop" ends the turn so the
      # agent resumes via a fresh marker after the dashboard approval.
      assert ChatCompletions.finish_reason_for(:input_required) == "stop"
      refute ChatCompletions.finish_reason_for(:input_required) == "tool_calls"
    end

    test "failed and done reasons also finish with stop" do
      assert ChatCompletions.finish_reason_for({:failed, :boom}) == "stop"
      assert ChatCompletions.finish_reason_for(:done) == "stop"
    end
  end

  describe "bar_connector/2" do
    # When two consecutive blockquote-rendered chunks are emitted to
    # opencode-attach, the blank line BETWEEN them needs a `> ` prefix
    # too — otherwise glamour breaks the vertical bar and renders two
    # separate blockquotes with a gap. `bar_connector/2` returns a
    # short pre-chunk string that bridges the bar; the empty case
    # returns "" so non-adjacent (prose-then-blockquote, etc.)
    # transitions stay clean.
    test "bridges blockquote→blockquote with a connector that paints the bar on the blank line" do
      out = ChatCompletions.bar_connector(:command, :command)
      # Concatenated with the next chunk's leading `\n> $ body\n`, this
      # produces `... \n> $ body1\n> \n> $ body2\n` — one continuous
      # blockquote with an empty bar line between the commands.
      assert out == "> "
    end

    test "all blockquote-style role pairs get the connector" do
      blockquote_roles = [:command, :tool, :system, :alert, :event_debug]

      for prev <- blockquote_roles, curr <- blockquote_roles do
        assert ChatCompletions.bar_connector(prev, curr) == "> ",
               "expected blockquote connector for #{inspect(prev)} → #{inspect(curr)}"
      end
    end

    test "blockquote → prose adds a blank-line connector to terminate the blockquote" do
      # Without an extra newline, markdown's lazy-continuation rule
      # pulls the prose line into the previous blockquote, so the
      # agent's reply gets the `>` bar treatment by mistake.
      assert ChatCompletions.bar_connector(:command, :assistant) == "\n"
      assert ChatCompletions.bar_connector(:tool, :reasoning) == "\n"
    end

    test "prose → blockquote returns no connector (no bar yet to extend)" do
      assert ChatCompletions.bar_connector(:assistant, :command) == ""
      assert ChatCompletions.bar_connector(:reasoning, :tool) == ""
    end

    test "nil previous (first chunk of the turn) never adds a connector" do
      assert ChatCompletions.bar_connector(nil, :command) == ""
      assert ChatCompletions.bar_connector(nil, :assistant) == ""
    end
  end
end
