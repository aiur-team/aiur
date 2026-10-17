defmodule Aiur.DecisionStore.Dedup do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionStore.Persistence
  alias Aiur.DecisionStore.Withdrawals

  # Creation-time dedup (#2099): same-ticket Commands with the same blocking
  # semantics collapse when their questions match exactly or paraphrase within
  # the short window. Matching requires enough substance that token overlap
  # means real overlap rather than a
  # tiny shared template (e.g. "Untouched open decision 1?" vs "…2?").
  @creation_dedup_window_seconds 5
  @creation_fuzzy_min_tokens 12
  # Sørensen–Dice token-overlap floor for paraphrases. The #2099 paraphrases
  # score ~0.59–0.79; 0.5 collapses them while leaving genuinely different
  # questions alone.
  @creation_question_similarity_threshold 0.5

  # One question is routinely filed as several Commands — an agent opens an
  # attention and files a `decision.requested` about the same thing, and the two
  # land as unrelated rows because dedup is keyed on `source_id`, which is
  # tool-call identity. Answering one then leaves its twins sitting in the
  # operator's queue asking a question that has already been decided.
  #
  # So when an answer lands, clear the siblings it just answered: same ticket,
  # same question, still open. `unresolvable_block?/1` still has the final say,
  # so an agent-filed blocking Command is never swept up — dismissal delivers
  # nothing to the agent waiting on it, and that invariant does not bend for a
  # sibling. Matching is exact-after-normalization on purpose; see
  # `normalized_question/1`.
  @spec supersede_duplicates(term(), term()) :: term()
  def supersede_duplicates(state, %Decision{} = answered) do
    case normalized_question(answered.question) do
      nil ->
        state

      question ->
        state.current
        |> Map.values()
        |> Enum.filter(&duplicate_of?(&1, answered, question))
        |> Enum.reduce(state, &dismiss_superseded(&2, &1, answered))
    end
  end

  defp duplicate_of?(%Decision{} = candidate, %Decision{} = answered, question) do
    candidate.decision_id != answered.decision_id and
      candidate.decision_status in [:open, :deferred] and
      is_nil(candidate.answer) and
      candidate.ticket.identifier == answered.ticket.identifier and
      candidate.authority == answered.authority and
      normalized_question(candidate.question) == question and
      not Withdrawals.unresolvable_block?(candidate)
  end

  defp dismiss_superseded(state, %Decision{} = duplicate, %Decision{} = answered) do
    actor = %{kind: :system, id: "superseded-by:#{answered.decision_id}"}

    case Persistence.build_and_persist_event(:decision_dismissed, duplicate, %{actor: actor}, DateTime.utc_now(), state) do
      {:ok, next_state, _updated} ->
        next_state

      # A duplicate that will not clear is a queue-hygiene miss, not a reason to
      # fail an answer the operator already gave. Leave it open and keep going.
      {:error, reason} ->
        Logger.warning(
          "decision supersede skipped decision_id=#{duplicate.decision_id} " <>
            "superseded_by=#{answered.decision_id} reason=#{inspect(reason)}"
        )

        Persistence.journal_failure_state(state, reason)
    end
  end

  # Deliberately conservative: case, surrounding whitespace, markdown emphasis
  # and a trailing `?`/`.` are noise, but nothing else is normalized away. Two
  # Commands must ask the *same* question to be collapsed, because the failure
  # mode of matching too loosely is dismissing a distinct open question the
  # operator never answered. The cost is that paraphrases of one question — the
  # shape in #1844's own #1640 example — are not linked; those stop doing harm
  # via the `blocking: false` fix in `DecisionAttention` instead.
  defp normalized_question(question) when is_binary(question) do
    normalized =
      question
      |> String.downcase()
      |> String.replace(~r/[`*_]+/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim_trailing("?")
      |> String.trim_trailing(".")
      |> String.trim()

    if normalized == "", do: nil, else: normalized
  end

  defp normalized_question(_question), do: nil

  # Creation-time dedup candidate search (#2099). Returns the newest live
  # Command on the same ticket whose question is substantially the same as the
  # incoming one.
  # Deliberately mirrors the conservative matching of `normalized_question/1` and
  # widens it with a token-overlap floor so paraphrases (the #2099 shape) also
  # collapse, while a genuinely different question still creates its own row.
  @spec find_creation_duplicate(term(), term()) :: term()
  def find_creation_duplicate(decision, state) do
    state.current
    |> Map.values()
    |> Enum.filter(&creation_duplicate_of?(&1, decision))
    |> Enum.max_by(& &1.created_at, DateTime, fn -> nil end)
  end

  defp creation_duplicate_of?(candidate, decision) do
    # A blocking Command gates dispatch and a non-blocking one does not, so the
    # two are not interchangeable duplicates even when the question matches
    # (#1965): an agent that files a blocking Command after a non-blocking
    # notice must not have the gate silently dropped, and vice versa.
    candidate.decision_id != decision.decision_id and
      candidate.decision_status in [:open, :deferred] and
      candidate.ticket.identifier == decision.ticket.identifier and
      candidate.blocking == decision.blocking and
      candidate.authority == decision.authority and
      creation_duplicate_match?(candidate, decision)
  end

  defp creation_duplicate_match?(candidate, decision) do
    case {normalized_question(candidate.question), normalized_question(decision.question)} do
      {nil, _} ->
        false

      {_, nil} ->
        false

      {normalized_a, normalized_b} ->
        normalized_a == normalized_b or
          (creation_paraphrase?(normalized_a, normalized_b) and
             within_creation_window?(candidate.created_at, decision.created_at, @creation_dedup_window_seconds))
    end
  end

  defp creation_paraphrase?(normalized_a, normalized_b) do
    tokens_a = tokens(normalized_a)
    tokens_b = tokens(normalized_b)

    length(tokens_a) + length(tokens_b) >= @creation_fuzzy_min_tokens and
      dice_similarity(tokens_a, tokens_b) >= @creation_question_similarity_threshold
  end

  defp within_creation_window?(%DateTime{} = candidate, %DateTime{} = incoming, window_seconds) do
    abs(DateTime.diff(incoming, candidate)) <= window_seconds
  end

  defp within_creation_window?(_candidate, _incoming, _window_seconds), do: false

  defp tokens(question) do
    question
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end

  defp dice_similarity(tokens_a, tokens_b) do
    a_set = MapSet.new(tokens_a)
    b_set = MapSet.new(tokens_b)
    intersection = MapSet.intersection(a_set, b_set) |> MapSet.size()
    denominator = MapSet.size(a_set) + MapSet.size(b_set)

    if denominator == 0, do: 0.0, else: 2 * intersection / denominator
  end
end
