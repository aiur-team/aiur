defmodule Aiur.Opencode.EventRow do
  @moduledoc """
  Shared formatter for the cross-ticket event ticker rows that show up
  in agent chat panes (R2 of the chat-pane follow-ups plan). Used by
  both `Aiur.Opencode.SessionWriter` (persists to SQL for re-attach
  scrollback) and `Aiur.Opencode.ChatCompletions` (chunks live deltas
  during the per-turn marker bridge SSE).

  Source: `Aiur.Events.DebugLog` entries — one per lifecycle mark on
  every event flowing through Aiur.

  ## Render shape

  Each row renders as a single dimmed line via `Aiur.Opencode.Style.dim/1`
  (a markdown blockquote prefix `> `). The body of the row is a
  natural-language sentence derived from:

    * the event lifecycle (📤 / 📥 / 📄)
    * the source ticket id (parsed from the `ticket.<id>.<surface>.<verb>` topic)
    * a verb phrase mapped from (`<surface>`, `<verb>`)
    * an optional summary from the event body (commit message, PR title,
      label name, etc.)

  Examples:

    * `📤 Opened a PR: "Add function_a"`                  (this agent emitted)
    * `📥 Ticket 100 pushed a new commit: "abc123"`       (incoming from blocker)
    * `📄 Ingested event from Ticket 100`                 (digest fold)

  ## Person

  - For `:publish` (the rendering agent emitted the event), use
    first-person: "📤 Pushed to its branch" / "📤 Opened a PR".
  - For `:receive` and `:read` (the rendering agent received or
    digested someone else's event), use third-person with the source
    ticket: "📥 Ticket 100 …".

  ## Relationship prefix (deferred)

  The user's spec asked for a "Blocker Ticket 100" prefix to make the
  cross-ticket relationship explicit. That requires the renderer to
  know whether `source_ticket` is a blocker, blockee, or unrelated
  watcher. Today the production `aiur_declare_blocker` tool wires the
  GitHub-side `blocked_by` relationship but does NOT auto-create a
  `Aiur.Events.SubscriptionStore` subscription tagged
  `relationship: :blocker`. That seam is the natural place to attach
  relationship metadata, but adding it is out of scope for this
  rendering change. Rows render as "Ticket <id>" for now; the prefix
  becomes "Blocker Ticket <id>" once the subscription metadata lands.

  ## Topic vocabulary

  Production topic shapes (as of this commit) — extend `verb_phrase/2`
  as new ones are introduced:

    * `ticket.<id>.pr.opened`                       → "opened a PR"
    * `ticket.<id>.pr.merged`                       → "merged its PR"
    * `ticket.<id>.pr.review_comment`               → "got a PR review comment"
    * `ticket.<id>.branch.push`                     → "pushed to its branch"
    * `ticket.<id>.issue.commented`                 → "got an issue comment"
    * `ticket.<id>.issue.label.added.agent.<state>` → "labeled <state>"
    * `ticket.<id>.agent.paused`                    → "was paused"
    * `ticket.<id>.agent.unpaused`                  → "was resumed"
    * `ticket.<id>.agent.blocked`                   → "declared itself blocked"
    * `ticket.<id>.agent.phase.<phase>.<step>`      → "<phase>: <step>"
    * `ticket.<id>.agent.error.tokens_exhausted`    → "ran out of tokens"
    * `ticket.<id>.agent.<name>`                    → "emitted <name>"

  Unknown shapes fall back to the raw topic suffix so nothing
  disappears silently.
  """

  alias Aiur.Opencode.Style

  @doc """
  Does this `DebugLog` entry belong to `identifier`'s chat pane?

  - If the entry carries an explicit `identifier` (the case for
    `:receive` from SubscriptionStore and `:read` from agent_runner),
    match on it directly.
  - If the entry has no identifier (the case for `:publish` from
    `Aiur.Events.Publisher`, which only knows the topic), match by
    parsing the topic prefix: `ticket.<id>.<surface>.<verb>` belongs
    to ticket `<id>`.

  Returns `false` for entries that don't belong to this identifier.
  """
  @spec matches?(map(), String.t()) :: boolean()
  def matches?(%{identifier: ident}, identifier)
      when not is_nil(ident) and is_binary(identifier),
      do: ident == identifier

  def matches?(%{topic: topic}, identifier)
      when is_binary(topic) and is_binary(identifier) do
    String.starts_with?(topic, "ticket.#{identifier}.")
  end

  def matches?(_entry, _identifier), do: false

  @doc """
  Format a `DebugLog` entry as a chat-pane ticker row, dimmed.

  `rendering_identifier` is the ticket id whose chat pane is showing
  the row — used to decide first-person vs third-person framing.

  Returns the rendered string ready for chunking via SSE or for
  writing as a `text` part body. Returns `nil` if the entry shape is
  unexpected.
  """
  @spec from(map(), String.t()) :: String.t() | nil
  def from(%{kind: kind, topic: topic} = entry, rendering_identifier)
      when kind in [:publish, :receive, :read] and is_binary(topic) and
             is_binary(rendering_identifier) do
    source_id = source_ticket_id(topic)
    body = Map.get(entry, :body)

    sentence =
      case kind do
        :publish -> publish_sentence(topic, source_id, body, rendering_identifier)
        :receive -> receive_sentence(topic, source_id, body)
        :read -> read_sentence(topic, source_id, body)
      end

    Style.dim(sentence)
  end

  def from(_, _), do: nil

  # Backwards-compatible 1-arg form — callers that don't know the
  # rendering identifier (e.g., older tests) fall back to third-person
  # framing for everything.
  @spec from(map()) :: String.t() | nil
  def from(%{kind: _, topic: _} = entry), do: from(entry, "_unknown")
  def from(_), do: nil

  # ── Per-kind sentence builders ─────────────────────────────────────

  defp publish_sentence(topic, source_id, body, rendering_identifier) do
    phrase = verb_phrase(topic, body)
    summary = summary_suffix(body)
    subject = subject(source_id, rendering_identifier, :first_person)

    "📤 " <> subject <> phrase <> summary
  end

  defp receive_sentence(topic, source_id, body) do
    phrase = verb_phrase(topic, body)
    summary = summary_suffix(body)
    subject = subject(source_id, nil, :third_person)

    "📥 " <> subject <> phrase <> summary
  end

  defp read_sentence(topic, source_id, _body) do
    case source_id do
      nil -> "📄 Ingested event " <> raw_topic_suffix(topic)
      id -> "📄 Ingested event from Ticket #{id}"
    end
  end

  # ── Subject framing ────────────────────────────────────────────────

  # First-person: "Pushed a new commit" (no "Ticket N" prefix when the
  # source IS the rendering agent).
  defp subject(source_id, rendering_identifier, :first_person)
       when is_binary(source_id) and is_binary(rendering_identifier) and
              source_id == rendering_identifier,
       do: ""

  defp subject(source_id, _rendering_identifier, :first_person)
       when is_binary(source_id),
       do: "Ticket #{source_id} "

  defp subject(nil, _rendering_identifier, :first_person), do: ""

  defp subject(source_id, _rendering_identifier, :third_person)
       when is_binary(source_id),
       do: "Ticket #{source_id} "

  defp subject(nil, _rendering_identifier, :third_person), do: ""

  # ── Topic → verb phrase ────────────────────────────────────────────

  # `verb_phrase/2` lowercases its first word at the call site (the
  # subject builder handles capitalization indirectly via empty/non-
  # empty subject prefix). Each clause returns a self-contained phrase
  # so a caller can prepend or omit a subject without grammar surgery.

  defp verb_phrase("ticket." <> rest, body) do
    case String.split(rest, ".", parts: 2) do
      [_id, suffix] -> phrase_for_suffix(suffix, body)
      _ -> rest
    end
  end

  defp verb_phrase(topic, _body), do: topic

  defp phrase_for_suffix("pr.opened", _body), do: "opened a PR"
  defp phrase_for_suffix("pr.merged", _body), do: "merged its PR"
  defp phrase_for_suffix("pr.review_comment", _body), do: "got a PR review comment"
  defp phrase_for_suffix("branch.push", _body), do: "pushed to its branch"
  defp phrase_for_suffix("issue.commented", _body), do: "got an issue comment"
  defp phrase_for_suffix("agent.paused", _body), do: "was paused"
  defp phrase_for_suffix("agent.unpaused", _body), do: "was resumed"
  defp phrase_for_suffix("agent.blocked", _body), do: "declared itself blocked"
  defp phrase_for_suffix("agent.error.tokens_exhausted", _body), do: "ran out of tokens"

  defp phrase_for_suffix("issue.label.added.agent." <> state, _body),
    do: "was labeled #{state}"

  defp phrase_for_suffix("agent.phase." <> rest, _body) do
    case String.split(rest, ".", parts: 2) do
      [phase, step] -> "phase #{phase}: #{step}"
      [phase] -> "entered phase #{phase}"
      _ -> "agent.phase.#{rest}"
    end
  end

  defp phrase_for_suffix("agent." <> name, _body), do: "emitted #{name}"

  defp phrase_for_suffix(other, _body), do: other

  # ── Body summary suffix ────────────────────────────────────────────

  # Extracts a short, human-readable string from common event-body
  # shapes. Returns "" when no useful summary is present so the
  # sentence ends cleanly without a stray colon.
  defp summary_suffix(nil), do: ""

  defp summary_suffix(body) when is_map(body) do
    case body_summary(body) do
      nil -> ""
      "" -> ""
      text -> ": \"#{truncate(text, 120)}\""
    end
  end

  defp summary_suffix(_), do: ""

  defp body_summary(body) do
    body
    |> get_in_any(["message", "title", "summary", "subject", "name", "label", "commit_message"])
  end

  # Look up the first present key, preferring string keys (the JSON
  # form) but falling back to atom keys for tests that build maps with
  # `%{message: "…"}`.
  defp get_in_any(map, keys) do
    Enum.find_value(keys, fn key ->
      val = Map.get(map, key) || Map.get(map, String.to_atom(key))

      case val do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end

  defp truncate(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if byte_size(text) <= max do
      text
    else
      binary_part(text, 0, max) <> "…"
    end
  end

  # ── Topic parsing helpers ──────────────────────────────────────────

  defp source_ticket_id(topic) do
    case String.split(topic, ".", parts: 3) do
      ["ticket", id, _rest] -> id
      _ -> nil
    end
  end

  defp raw_topic_suffix(topic) do
    case String.split(topic, ".", parts: 3) do
      ["ticket", _id, rest] -> "(#{rest})"
      _ -> "(#{topic})"
    end
  end
end
