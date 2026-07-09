defmodule Aiur.Opencode.ChatCompletionsTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Aiur.Opencode.ChatCompletions
  alias Aiur.Opencode.{ActiveTurns, TokenRegistry}

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

  # ── Wave 0: conn-path characterization ────────────────────────────────────

  # Stub adapter whose chunk/2 returns {:error, :closed} so the chunk/4
  # closed-conn tolerance test can exercise the graceful-error path without
  # needing a real disconnected socket.
  defmodule ClosedConnAdapter do
    @behaviour Plug.Conn.Adapter

    defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
    defdelegate send_file(state, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
    defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
    defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
    defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
    defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
    defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn

    def chunk(_state, _body), do: {:error, :closed}
  end

  describe "stream_codex_turn: phantom and late-close conn paths" do
    test "phantom turn (no ActiveTurns entry) closes with finish_reason stop" do
      identifier = "phantom-#{System.unique_integer()}"

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:phantom-abc"}]
      }

      # No ActiveTurns.put → lookup returns :not_found → finalize_stream(:done) → "stop"
      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end

    test "late close ({:closed, reason}) renders the reason content then closes with stop" do
      identifier = "late-#{System.unique_integer()}"
      turn_id = "late-turn-#{System.unique_integer()}"

      :ok = ActiveTurns.put(identifier, turn_id)
      :ok = ActiveTurns.mark_closed(identifier, turn_id, {:failed, :boom})

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:#{turn_id}"}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      # finalize_stream({:failed, reason}) chunks the inspect(reason) before "stop"
      assert result.resp_body =~ "boom"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "nudge marker" do
    test "nudge marker returns an empty data:[DONE] SSE stream" do
      body = %{
        "model" => "issue-nudge-#{System.unique_integer()}",
        "messages" => [%{"role" => "user", "content" => "__aiur_stream__:nudge:1"}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      assert result.resp_body == "data: [DONE]\n\n"
    end
  end

  describe "replay: stream marker not-found path" do
    test "stream marker with no session renders **system:** message not found then stop" do
      # No bearer token → resolve_session_for_replay returns nil
      # → nil && Db.fetch_message_with_parts(nil, id) = nil → not-found branch
      body = %{
        "model" => "issue-replay-#{System.unique_integer()}",
        "messages" => [%{"role" => "user", "content" => "__aiur_stream__:msg_ABCDEF"}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 200
      assert result.resp_body =~ "message not found"
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "operator dispatch: ack-fast SSE close" do
    test "operator text path closes SSE with stop as soon as send_operator accepts" do
      identifier = "ack-#{System.unique_integer()}"
      token = "ack-tok-#{System.unique_integer()}"
      :ok = TokenRegistry.put(token, 1, 1)

      # A pure scaffold reminder (no real operator text) normalizes to ""
      # → send_operator returns {:ok, :noop} → stream_turn closes SSE with "stop"
      # without entering any receive loop (ack-fast contract).
      noop_text = "<system-reminder>cwd changed to /tmp</system-reminder>"

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => noop_text}],
        "stream" => true
      }

      test_conn =
        :post
        |> conn("/")
        |> put_req_header("authorization", "Bearer #{token}")

      result = ChatCompletions.handle(body, test_conn)

      assert result.status == 200
      assert result.resp_body =~ ~s("finish_reason":"stop")
    end
  end

  describe "validate_body/1 taxonomy (via dispatch path)" do
    test "body exceeding 65 536 bytes yields a 400 body-too-large response" do
      body = %{
        "model" => "issue-vb-#{System.unique_integer()}",
        "messages" => [%{"role" => "user", "content" => String.duplicate("x", 65_537)}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 400
      assert Jason.decode!(result.resp_body)["error"] =~ "body too large"
    end

    test "invalid UTF-8 in the last user message yields a 400 invalid-utf8 response" do
      body = %{
        "model" => "issue-vb-#{System.unique_integer()}",
        # <<0xFF, 0xFE>> is not valid UTF-8
        "messages" => [%{"role" => "user", "content" => <<0xFF, 0xFE>>}]
      }

      result = ChatCompletions.handle(body, conn(:post, "/"))

      assert result.status == 400
      assert Jason.decode!(result.resp_body)["error"] =~ "invalid_utf8"
    end
  end

  describe "chunk/4 closed-conn tolerance" do
    test "chunk writes on a disconnected conn return the conn unchanged without raising" do
      # ClosedConnAdapter delegates send_chunked to the real adapter (so the
      # conn transitions to :chunked state) but returns {:error, :closed} for
      # every chunk write. The phantom-turn path calls send_chunked once then
      # chunk/4 once for the finish chunk; chunk/4 must handle {:error, :closed}
      # gracefully — log once and return the conn unchanged rather than raising.
      identifier = "chunk-tol-#{System.unique_integer()}"

      body = %{
        "model" => "issue-#{identifier}",
        "messages" => [%{"role" => "user", "content" => "__aiur_turn__:phantom-chunk-tol"}]
      }

      base_conn = conn(:post, "/")
      {_, adapter_state} = base_conn.adapter
      stub_conn = %{base_conn | adapter: {ClosedConnAdapter, adapter_state}}

      # Must not raise; chunk/4 handles {:error, :closed} by returning conn
      result = ChatCompletions.handle(body, stub_conn)
      assert %Plug.Conn{} = result
    end
  end
end
