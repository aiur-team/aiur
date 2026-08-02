defmodule Aiur.Events.Topic do
  @moduledoc """
  AMQP 0-9-1 topic-exchange pattern matcher.

  Implements the canonical wildcard semantics used by RabbitMQ, NATS JetStream
  subject hierarchies, and MQTT topics:

    * `*` matches exactly one segment between dots
    * `#` matches zero or more segments

  Pure module — no GenServer, no ETS, no process state. Safe to call from any
  context including async tests. Used by `Aiur.Events.Exchange` for subscription
  dispatch and by `Aiur.Alerts` for glob-keyed alerts-file lookup (one
  matcher, two consumers, no drift).

  ## Specificity ordering

  For "first-match-wins" alert lookup, callers sort candidate patterns by
  `specificity_score/1` descending: more literal segments score higher, then
  `*` segments, then `#` segments. Ties break lexicographically by pattern
  string. Matches Executor intuition that the more-specific pattern wins.
  """

  @doc """
  Returns `true` iff `topic` matches `pattern` under AMQP topic-exchange
  semantics.

  Both inputs are dot-delimited strings; `*` and `#` in the pattern are
  wildcards as defined in the module doc.
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(pattern, topic) when is_binary(pattern) and is_binary(topic) do
    match_segments(String.split(pattern, "."), String.split(topic, "."))
  end

  # `#` at end consumes remainder including zero.
  defp match_segments(["#"], _topic_rest), do: true

  # Both exhausted simultaneously — match.
  defp match_segments([], []), do: true

  # Pattern exhausted but topic remains — no match.
  defp match_segments([], _topic_rest), do: false

  # Topic exhausted but pattern remains. Only matches if every remaining
  # pattern segment is `#` (each `#` can match zero words).
  defp match_segments(pattern_rest, []) do
    Enum.all?(pattern_rest, &(&1 == "#"))
  end

  # `#` mid-pattern — greedy backtracking. Try matching zero topic segments
  # first (advance pattern), then 1, then 2, ... until either matches or
  # we exhaust the topic.
  defp match_segments(["#" | pattern_rest], topic_rest) do
    match_segments(pattern_rest, topic_rest) or
      match_segments(["#" | pattern_rest], tl(topic_rest))
  end

  # `*` consumes exactly one topic segment.
  defp match_segments(["*" | pattern_rest], [_topic_seg | topic_rest]) do
    match_segments(pattern_rest, topic_rest)
  end

  # Literal segment — must equal topic segment.
  defp match_segments([seg | pattern_rest], [seg | topic_rest]) do
    match_segments(pattern_rest, topic_rest)
  end

  # Literal mismatch.
  defp match_segments([_, _ | _], [_ | _]), do: false
  defp match_segments([_], [_ | _]), do: false

  @doc """
  Returns an integer specificity score for `pattern`. Higher score = more
  specific.

  Scoring: `(literal_count * 100) - (star_count * 10) - (hash_count * 1)`.
  Designed so that any pattern with more literals always outranks any pattern
  with fewer literals, regardless of wildcard mix. Ties between equal-shape
  patterns are broken lexicographically by the caller using `pattern` as the
  tiebreaker.
  """
  @spec specificity_score(String.t()) :: integer()
  def specificity_score(pattern) when is_binary(pattern) do
    segments = String.split(pattern, ".")
    literals = Enum.count(segments, fn s -> s != "*" and s != "#" end)
    stars = Enum.count(segments, &(&1 == "*"))
    hashes = Enum.count(segments, &(&1 == "#"))
    literals * 100 - stars * 10 - hashes
  end
end
