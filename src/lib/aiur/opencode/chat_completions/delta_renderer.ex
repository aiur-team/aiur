defmodule Aiur.Opencode.ChatCompletions.DeltaRenderer do
  @moduledoc """
  Transcript event → markdown SSE delta.

  Converts live transcript events from `AgentPubSub` into the markdown strings
  that the bridge streams as OpenAI chat-completion deltas. Handles role
  filtering, command/tool/diff/reasoning formatting, and blockquote-bar
  connectors. No side effects; no process interaction.
  """

  alias Aiur.Opencode.Style

  # Map a transcript event to the assistant-SSE delta the bridge should
  # stream for it, or `:drop` when the event must not stream through the
  # assistant response at all.
  #
  # `:user` events always drop. Opencode echoes locally-typed input
  # natively, and a remote-origin (Remote Control app) user message is
  # persisted as a genuine user-role message by `Aiur.Opencode.SessionWriter`
  # so it renders as a user turn — streaming it here would render the
  # operator's words as assistant speech.
  @doc false
  @spec transcript_delta(map(), atom() | nil) :: {:delta, String.t(), atom()} | :drop
  def transcript_delta(%{role: :user}, _last_role), do: :drop

  def transcript_delta(%{role: role, body: body} = event, last_role)
      when role in [:assistant, :command, :system, :alert, :reasoning, :tool] do
    {:delta, bar_connector(last_role, role) <> format_delta(role, body, event), role}
  end

  def transcript_delta(_event, _last_role), do: :drop

  # Format a transcript event's body as a chat-completion delta. The
  # SQL part written by SessionWriter is authoritative; this is the
  # live-stream summary. Public so tests can exercise it without going
  # through Plug.Conn.
  #
  # Commands and generic tools render through `Style.dim/1` so opencode's
  # glamour pipeline draws them as a dim blockquote with a left-margin
  # bar — same visual vocabulary as :system/:alert and the edit/read
  # tool rows. This subordinates command chatter under the agent's prose
  # and shares one visual language across non-agent content.
  @doc false
  @spec format_delta(atom(), String.t()) :: String.t()
  def format_delta(role, body), do: format_delta(role, body, %{})

  @doc """
  Format a transcript event into an SSE chunk-ready string. The
  optional `event` map carries the full transcript event (role, body,
  payload, …) so role-specific formatters can pick up payload fields
  the body string alone doesn't carry. Currently used by `:tool`'s
  `edit` branch to surface the file-change diff hunks via a fenced
  ```diff block beneath the summary line.
  """
  @spec format_delta(atom(), String.t(), map()) :: String.t()
  def format_delta(:command, body, _event) do
    # Convert literal `\n` sequences from codex's transcript JSON
    # into real newlines so multi-line heredocs render as multiple
    # rows in the chat pane instead of showing the escape glyphs.
    normalized = normalize_escaped_newlines(body)
    render_dim_blockquote("$ ", normalized)
  end

  def format_delta(:tool, body, event) do
    cond do
      String.starts_with?(body, "edit ") ->
        diff = edit_diff_from_payload(event)
        path = String.trim_leading(body, "edit ")
        summary = render_dim_blockquote("✏️  ", "edit " <> path)

        if diff == "" do
          summary
        else
          # Show the summary then the actual diff hunks. Glamour
          # renders ```diff fences with red/green highlighting on
          # +/- lines — close to the native opencode edit-tool look
          # without forking opencode.
          String.trim_trailing(summary) <> "\n\n```diff\n#{diff}\n```\n"
        end

      String.starts_with?(body, "read ") ->
        path = String.trim_leading(body, "read ")
        render_dim_blockquote("📖 ", "read " <> path)

      true ->
        normalized = normalize_escaped_newlines(body)
        render_dim_blockquote("→ ", normalized)
    end
  end

  def format_delta(:reasoning, body, _event), do: "\n_#{body}_\n"
  def format_delta(:alert, body, _event), do: "\n> 🔔 #{body}\n"
  def format_delta(:system, body, _event), do: "\n> #{body}\n"
  def format_delta(_role, body, _event), do: body

  # Render a command-style line as `> <prefix>\`<body>\`` so the
  # leading prefix (emoji + space, or `$ `) stays OUTSIDE the
  # inline-code span. Glamour paints inline code via `markdownCode`
  # (theme: `darkStep11` grey), giving us a visibly-dim body while
  # the emoji prefix and the blockquote bar keep their normal
  # colors.
  #
  # When the body contains literal newlines OR backticks, falls
  # back to the bar-only blockquote via `Style.dim/1`. Inline code
  # can't wrap content with `\``s (they'd close the span midway)
  # or `\n`s (inline code is a one-line construct).
  defp render_dim_blockquote(prefix, body) do
    if String.contains?(body, "\n") or String.contains?(body, "`") do
      "\n" <> Style.dim(prefix <> body) <> "\n"
    else
      "\n> #{prefix}`#{body}`\n"
    end
  end

  # Codex transcripts arrive as JSON-decoded strings. A shell
  # `$'…\n…'` heredoc gets stored as a single Elixir string where
  # the `\n` characters are real newlines (JSON decoded them) — but
  # SOMETIMES the agent sees them as escape sequences (literal
  # `\` followed by `n`), so we normalise the literal form too.
  defp normalize_escaped_newlines(body) do
    body
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
  end

  # Pull the diff content out of a `:tool` transcript event for the
  # `edit` tool. `Aiur.Codex.Transcript.build_tool_payload/2` stuffs
  # the joined diff into the payload's `:output` field; we surface
  # it here when present.
  #
  # Codex emits two shapes for file edits:
  #   1. A unified diff (lines start with `@@`, `+`, `-`, ` `) when
  #      the edit was a patch.
  #   2. The full new file content with no diff markers when the
  #      edit was a whole-file replace or new-file create.
  #
  # Glamour renders ```diff blocks by coloring lines based on their
  # leading character: `+` → green, `-` → red, ` ` → context. Shape
  # 1 already paints correctly. For shape 2, every line is treated
  # as context (no color). We detect shape 2 and prefix each line
  # with `+ ` so the whole block reads as additions (green), making
  # the change visible at a glance.
  defp edit_diff_from_payload(%{payload: %{output: output, tool: "edit"}})
       when is_binary(output) and output != "" do
    if looks_like_unified_diff?(output) do
      output
    else
      output
      |> String.split("\n")
      |> Enum.map_join("\n", &("+ " <> &1))
    end
  end

  defp edit_diff_from_payload(_), do: ""

  defp looks_like_unified_diff?(text) do
    String.contains?(text, "\n@@ ") or
      String.starts_with?(text, "@@ ") or
      String.contains?(text, "\n+++") or
      String.contains?(text, "\n--- ")
  end

  @doc """
  Inter-chunk connector for the chat-completion delta stream. Two
  cases that need handling:

  1. **blockquote → blockquote** — the blank line between them must
     carry the `>` bar or glamour renders two separate blockquotes
     with a visible gap. Connector: `"> "`. Combined with the
     trailing `\\n` of the previous chunk and the leading `\\n` of
     the next, this produces a `> ` line on its own (continuous
     vertical bar through the gap).

  2. **blockquote → prose** — without a connector here, markdown's
     lazy-continuation rule pulls the next prose line INTO the
     prior blockquote because only one `\\n` separates them.
     Connector: `"\\n"` (extra blank line to terminate the
     blockquote before prose starts).

  All other transitions return `""`. `nil` previous role means
  "first chunk of the turn" — never a connector.
  """
  @spec bar_connector(atom() | nil, atom()) :: String.t()
  def bar_connector(prev_role, curr_role) do
    cond do
      blockquote_role?(prev_role) and blockquote_role?(curr_role) -> "> "
      blockquote_role?(prev_role) and not blockquote_role?(curr_role) -> "\n"
      true -> ""
    end
  end

  defp blockquote_role?(role) when role in [:command, :tool, :system, :alert, :event_debug], do: true
  defp blockquote_role?(_), do: false
end
