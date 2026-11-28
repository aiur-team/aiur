defmodule Aiur.DecisionStore.CreatorOverlap do
  @moduledoc false

  alias Aiur.{Bounded, Decision, DecisionPubSub}
  alias Aiur.DecisionStore.Dedup
  alias Aiur.Protocol.MapAccess

  @answer_window_seconds 7 * 24 * 60 * 60
  @same_request_fields ~w(kind audience authority blocking urgency reversibility context options artifacts media questions native)a

  @spec find(Decision.t(), keyword(), %{String.t() => Decision.t()}) :: {Decision.t(), :open | :answered} | :distinct | :ineligible
  def find(decision, opts, current) do
    if creator_request?(decision, opts[:requester]) and matchable?(decision) and opts[:questions] in [nil, []] and is_nil(opts[:native]) do
      decision = %{decision | requester: opts[:requester]}
      question = comparable_question(decision.question)

      current
      |> Map.values()
      |> Enum.filter(&same_question?(&1, decision, question))
      |> Enum.flat_map(&available_match(&1, decision.created_at))
      |> Enum.max_by(fn {prior, _status, at} -> {DateTime.to_unix(at, :microsecond), prior.decision_id} end, fn -> nil end)
      |> case do
        nil -> :distinct
        {prior, status, _at} -> {prior, status}
      end
    else
      :ineligible
    end
  end

  @spec link(String.t()) :: String.t()
  def link(decision_id), do: "/commands/" <> URI.encode_www_form(decision_id)

  @spec report(term(), keyword()) :: term()
  def report({:ok, %{creator_overlap: overlap}} = result, opts) do
    ticket = MapAccess.get(opts[:requester], :ticket) || MapAccess.get(opts[:ticket], :identifier)
    DecisionPubSub.broadcast_creator_overlap(ticket, overlap)
    result
  end

  def report(result, _opts), do: result

  defp creator_request?(decision, requester) do
    decision.audience != :executor and (decision.audience == :creator or decision.authority == :human_required or match?(%{kind: :executor}, requester))
  end

  defp matchable?(decision) do
    decision.kind not in ["legacy_attention", "native_question", "gateway_grant"] and
      is_nil(decision.legacy_attention) and decision.reversibility == :reversible and
      decision.context[:authority_basis] not in ["security", "external_publication", "spend"]
  end

  defp same_question?(prior, decision, question) do
    question != "" and prior.decision_id != decision.decision_id and matchable?(prior) and same_scope?(prior, decision) and
      Map.take(prior, @same_request_fields) == Map.take(decision, @same_request_fields) and
      (comparable_question(prior.question) == question or Dedup.creation_duplicate_of?(prior, decision))
  end

  defp same_scope?(%{ticket: %{identifier: "executor"}, requester: prior}, %{ticket: %{identifier: "executor"}, requester: request}) do
    match?(%{ticket: ticket} when is_binary(ticket) and ticket != "", request) and prior == request
  end

  defp same_scope?(%{ticket: %{identifier: ticket, url: prior_url}}, %{ticket: %{identifier: ticket, url: url}}) when ticket != "executor",
    do: prior_url == url or same_repository?(prior_url, url)

  # Ticket-scoped creators can only see their own open Commands. Across
  # tickets, link an earlier answer only when there's no new delivery target.
  defp same_scope?(prior, decision) do
    prior.ticket.identifier != "executor" and decision.ticket.identifier != "executor" and not is_nil(prior.answer) and
      not decision.blocking and is_binary(decision.context.long_context_markdown) and same_repository?(prior.ticket.url, decision.ticket.url)
  end

  defp same_repository?(left, right) do
    with {:ok, left_repo} <- Bounded.github_issue_repository(left),
         {:ok, right_repo} <- Bounded.github_issue_repository(right) do
      Bounded.same_repository?(left_repo, right_repo)
    else
      _ -> false
    end
  end

  defp available_match(%{decision_status: status, answer: nil} = prior, _now) when status in [:open, :deferred],
    do: [{prior, :open, prior.created_at}]

  defp available_match(prior, now) do
    with true <- prior.decision_status in [:decided, :acknowledged, :resolved],
         %{accepted_at: accepted_at, rejected: false, decision_version: version} <- Decision.active_answer(prior),
         true <- version == prior.version,
         age when age >= 0 and age <= @answer_window_seconds <- DateTime.diff(now, accepted_at) do
      [{prior, :answered, accepted_at}]
    else
      _ -> []
    end
  end

  # Strip only polite prefixes and terminal punctuation. Preserve the spelling
  # and order of the actual terms, including identifiers, quantities and negation.
  defp comparable_question(question) do
    question
    |> String.trim()
    |> String.replace(~r/^(?:(?:could you|can you|please) confirm whether |please )/iu, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim_trailing("?")
    |> String.trim_trailing(".")
    |> String.trim()
  end
end
