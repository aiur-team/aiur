defmodule Aiur.Orchestrator.ReviewFreshness do
  @moduledoc """
  Decides whether a trusted PR comment or review submission still describes the
  pull request's *current* head.

  GitHub never clears `reviewDecision` when an agent addresses the findings of a
  `CHANGES_REQUESTED` review — only a brand new review moves it. Routing a
  ticket to `agent:rework` off that stale signal produces a loop with no exit:
  the agent finds nothing to rework, pushes a develop merge to prove liveness,
  the push dismisses any approval that would have released the ticket, and the
  next poll routes it straight back to rework (#1756).

  Two facts break the loop, and both are carried on the published comment event
  by `Aiur.Events.GithubCommentsPoller` so this stays a pure function:

    * `review_decision` — an `APPROVED` pull request is never rework, whatever
      an older review said.
    * `head_committed_at` — a review submitted before the current head commit
      was authored is, by construction, not a judgement about that head.

  Both checks fail open. When the poller could not resolve the pull request
  context (the REST fallback path, an overflowed GraphQL batch), the event
  carries no context and routing behaves exactly as it did before.
  """

  @approved_decision "APPROVED"

  @typedoc "Why a comment event must not move its ticket to rework."
  @type skip_reason :: :approved_pull_request | :stale_review

  @doc """
  Returns the reason this event must not route its ticket to `agent:rework`, or
  `nil` when the event is a live judgement about the current head.
  """
  @spec rework_skip_reason(map()) :: skip_reason() | nil
  def rework_skip_reason(event) when is_map(event) do
    context = pull_request_context(event)

    cond do
      approved?(context) -> :approved_pull_request
      stale?(event, context) -> :stale_review
      true -> nil
    end
  end

  def rework_skip_reason(_event), do: nil

  defp approved?(context) do
    case fetch(context, "review_decision") do
      decision when is_binary(decision) -> String.upcase(decision) == @approved_decision
      _other -> false
    end
  end

  # Strictly older: a review submitted in the same second as the head commit is
  # ambiguous, and the safe reading of an ambiguous review is that it is live.
  defp stale?(event, context) do
    with %DateTime{} = head_at <- parse(fetch(context, "head_committed_at")),
         %DateTime{} = submitted_at <- comment_submitted_at(event) do
      DateTime.compare(submitted_at, head_at) == :lt
    else
      _other -> false
    end
  end

  defp comment_submitted_at(event) do
    comment = fetch(event, "comment") || %{}

    if is_map(comment) do
      parse(fetch(comment, "submitted_at") || fetch(comment, "created_at"))
    end
  end

  defp pull_request_context(event) do
    case fetch(event, "pull_request") do
      %{} = context -> context
      _other -> %{}
    end
  end

  # Event payloads reach the orchestrator with atom keys from in-process
  # publishes and string keys after a JSON round trip through the event store.
  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp fetch(_map, _key), do: nil

  defp parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse(_value), do: nil
end
