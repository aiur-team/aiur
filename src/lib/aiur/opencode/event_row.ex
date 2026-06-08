defmodule Aiur.Opencode.EventRow do
  @moduledoc """
  Formats `Aiur.Events.DebugLog` entries as one-line chat-pane ticker
  rows. Each row is a natural-language sentence (`💬 opened a PR:
  "…"` / `📬 Ticket 100 pushed to its branch: "…"` / `📄 Ingested
  event from Ticket 100`) wrapped in `Aiur.Opencode.Style.dim/1`.

  Used by both `Aiur.Opencode.SessionWriter` (SQL writes for
  re-attach scrollback) and `Aiur.Opencode.ChatCompletions` (live SSE
  deltas inside the per-turn marker bridge).

  Person framing depends on whose chat pane is rendering: `:publish`
  events on the rendering agent's own topic use first-person (no
  subject prefix); everything else uses third-person with the source
  ticket as subject. Add a clause to `phrase_for_suffix/2` to teach
  the renderer a new topic shape.

  Self-receive suppression: when the agent's own subscription fans
  an event back to itself (kind: `:receive`, topic starts with
  `ticket.<rendering_identifier>.`), `from/2` returns nil. The
  matching `:publish` line is already visible; the self-receive is
  pure noise.
  """

  alias Aiur.Opencode.Style

  @body_summary_keys ~w(message title summary subject name label commit_message)

  # GithubFirehose payloads keep user content under nested maps —
  # `:comment.body` for issue/PR comments, `:pr.title`/`:pr.body` for
  # PRs, `:review.body` for reviews, `:commits[*].message` for pushes.
  # Walk these in order so the ticker row surfaces the actual content
  # instead of "got an issue comment" with no quoted text.
  @nested_body_paths [
    [:comment, "body"],
    [:review, "body"],
    [:pr, "title"],
    [:pr, "body"]
  ]

  @body_summary_max 120

  @doc """
  Does this `DebugLog` entry belong to `identifier`'s chat pane?

  Prefers the entry's explicit `identifier` field (set by
  `SubscriptionStore` for `:receive` and `agent_runner` for `:read`).
  Falls back to parsing the topic prefix `ticket.<id>.` for entries
  without an explicit identifier (the `:publish` path from
  `Aiur.Events.Publisher`).
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
  Render a `DebugLog` entry as a dimmed chat-pane row. Returns `nil`
  for malformed entries so callers can skip them.

  `rendering_identifier` is the chat pane's owning ticket id — used
  to decide first-person vs third-person framing.
  """
  @spec from(map(), String.t()) :: String.t() | nil
  def from(%{kind: kind, topic: topic} = entry, rendering_identifier)
      when kind in [:publish, :receive, :read] and is_binary(topic) and
             is_binary(rendering_identifier) do
    source_id = source_ticket_id(topic)
    body = Map.get(entry, :body)

    if self_receive?(kind, source_id, rendering_identifier) do
      # Agent's own subscription fanned an event back to itself.
      # The matching :publish row already rendered above; the
      # self-receive is duplicate noise.
      nil
    else
      sentence =
        case kind do
          :publish -> publish_sentence(topic, source_id, body, rendering_identifier)
          :receive -> receive_sentence(topic, source_id, body)
          :read -> read_sentence(topic, source_id)
        end

      Style.dim(sentence)
    end
  end

  def from(_, _), do: nil

  defp self_receive?(:receive, source_id, rendering_identifier)
       when is_binary(source_id) and is_binary(rendering_identifier),
       do: source_id == rendering_identifier

  defp self_receive?(_kind, _source_id, _rendering_identifier), do: false

  # ── Per-kind sentence builders ─────────────────────────────────────

  defp publish_sentence(topic, source_id, body, rendering_identifier) do
    "💬 " <> subject(source_id, rendering_identifier) <> verb_phrase(topic, body) <> summary_suffix(body)
  end

  defp receive_sentence(topic, source_id, body) do
    "📬 " <> subject(source_id, nil) <> verb_phrase(topic, body) <> summary_suffix(body)
  end

  defp read_sentence(topic, source_id) do
    case source_id do
      nil -> "📄 Ingested event " <> raw_topic_suffix(topic)
      id -> "📄 Ingested event from Ticket #{id}"
    end
  end

  # First-person when the source ticket IS the rendering agent;
  # third-person ("Ticket N ") otherwise. Returns "" for unparseable
  # source ids so the sentence falls back to a bare verb phrase.
  defp subject(source_id, rendering_identifier)
       when is_binary(source_id) and is_binary(rendering_identifier) and
              source_id == rendering_identifier,
       do: ""

  defp subject(source_id, _rendering_identifier) when is_binary(source_id),
    do: "Ticket #{source_id} "

  defp subject(nil, _rendering_identifier), do: ""

  # ── Topic → verb phrase ────────────────────────────────────────────

  defp verb_phrase("ticket." <> rest, body) do
    case String.split(rest, ".", parts: 2) do
      [_id, suffix] -> phrase_for_suffix_with_body(suffix, body) || phrase_for_suffix(suffix)
      _ -> rest
    end
  end

  defp verb_phrase(topic, _body), do: topic

  defp phrase_for_suffix("pr.opened"), do: "opened a PR"
  defp phrase_for_suffix("pr.merged"), do: "merged its PR"
  defp phrase_for_suffix("pr.review_comment"), do: "got a PR review comment"
  defp phrase_for_suffix("branch.push"), do: "pushed to its branch"
  defp phrase_for_suffix("issue.commented"), do: "got an issue comment"
  defp phrase_for_suffix("agent.paused"), do: "was paused"
  defp phrase_for_suffix("agent.unpaused"), do: "was resumed"
  defp phrase_for_suffix("agent.blocked"), do: "declared itself blocked"
  defp phrase_for_suffix("agent.error.tokens_exhausted"), do: "ran out of tokens"

  defp phrase_for_suffix("issue.label.added.agent." <> state),
    do: "was labeled #{state}"

  defp phrase_for_suffix("agent.phase." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [phase, step] -> "phase #{phase}: #{step}"
      [phase] -> "entered phase #{phase}"
      _ -> "agent.phase.#{rest}"
    end
  end

  defp phrase_for_suffix("agent." <> name), do: "emitted #{name}"

  defp phrase_for_suffix(other), do: other

  # Hook for verb phrases that depend on payload contents (e.g., to
  # disambiguate semantically-different payloads under one topic).
  # Default fall-through is nil so the standard phrase wins.
  defp phrase_for_suffix_with_body(_suffix, _body), do: nil

  # ── Body summary suffix ────────────────────────────────────────────

  defp summary_suffix(body) when is_map(body) do
    case extract_body_text(body) do
      nil -> ""
      text -> ": \"#{truncate(text, @body_summary_max)}\""
    end
  end

  defp summary_suffix(_), do: ""

  # Walk the top-level @body_summary_keys first (where event-payload
  # writers put `:message`, `:summary`, etc.), then fall through to
  # the nested paths GithubFirehose's payload uses (comment.body,
  # pr.title, pr.body, review.body). Returns the first non-empty
  # binary or nil.
  defp extract_body_text(map) do
    first_present_string(map, @body_summary_keys) || first_present_nested(map, @nested_body_paths)
  end

  defp first_present_string(map, keys) do
    Enum.find_value(keys, fn key ->
      raw = Map.get(map, key) || Map.get(map, String.to_atom(key))
      normalize_text(raw)
    end)
  end

  defp first_present_nested(map, paths) do
    Enum.find_value(paths, fn path -> map |> get_path(path) |> normalize_text() end)
  end

  defp get_path(map, []) when is_map(map), do: nil
  defp get_path(nil, _path), do: nil

  defp get_path(map, [key | rest]) when is_map(map) do
    value =
      cond do
        is_atom(key) -> Map.get(map, key) || Map.get(map, Atom.to_string(key))
        is_binary(key) -> Map.get(map, key) || safe_atom_lookup(map, key)
        true -> nil
      end

    case rest do
      [] -> value
      _ -> get_path(value, rest)
    end
  end

  defp get_path(_other, _path), do: nil

  defp safe_atom_lookup(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp normalize_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_), do: nil

  # Codepoint-safe truncation — `binary_part` could cut a multi-byte
  # UTF-8 character in half and produce invalid binary.
  defp truncate(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "…"
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
