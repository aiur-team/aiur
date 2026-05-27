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
    test ":command renders as a dim blockquote" do
      out = ChatCompletions.format_delta(:command, "git status --short")
      assert out == "\n> $ git status --short\n"
    end

    test ":command with multi-line body keeps the blockquote bar on every line" do
      heredoc = "gh issue comment 101 --body-file - <<'EOF'\nfirst\nsecond\nEOF"
      out = ChatCompletions.format_delta(:command, heredoc)

      # Every line of the body gets the `> ` prefix so opencode's
      # glamour pipeline keeps the dim bar unbroken across the heredoc.
      assert String.starts_with?(out, "\n> $ gh issue comment")
      assert String.contains?(out, "\n> first\n")
      assert String.contains?(out, "\n> second\n")
      assert String.contains?(out, "\n> EOF\n")
    end

    test ":tool with 'edit <path>' body renders as a file-edit blockquote" do
      out = ChatCompletions.format_delta(:tool, "edit lib/foo.ex")
      assert out == "\n> ✏️  edit lib/foo.ex\n"
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

      assert String.starts_with?(out, "\n> ✏️  edit lib/foo.ex\n")
      assert out =~ "```diff"
      assert out =~ "+world!"
      assert out =~ "-world"
    end

    test ":tool 'edit' without a diff payload falls back to summary-only" do
      out = ChatCompletions.format_delta(:tool, "edit lib/foo.ex", %{})
      assert out == "\n> ✏️  edit lib/foo.ex\n"
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
      assert out == "\n> 📖 read lib/foo.ex\n"
    end

    test ":tool with a non-file-op title falls back to a dim blockquote" do
      out = ChatCompletions.format_delta(:tool, "emit_alert")
      assert out == "\n> → emit_alert\n"
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
