defmodule Aiur.Orchestrator.CiLifecycle.TerminalEvent do
  @moduledoc """
  Publishes the terminal CI event and keeps the ticket subscribed to it.
  """

  alias Aiur.Events.Publisher
  alias Aiur.Events.Sanitizer
  alias Aiur.Events.UniversalSubscriptions
  alias Aiur.Issue
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.State
  require Logger

  @ci_failure_excerpt_message_max 1_200

  @doc false
  @spec publish_ci_terminal_event(State.t(), Issue.t(), map(), :passed | :failed) :: State.t()
  def publish_ci_terminal_event(%State{} = state, %Issue{} = issue, result, outcome) do
    target = CiLifecycle.ci_target_for_issue(issue)
    topic = "ticket.#{target}.ci.#{outcome}"

    payload =
      %{
        source: :github,
        head_sha: Map.get(result, :head_sha),
        pr_number: Map.get(result, :pr_number),
        checks: Map.get(result, :failures, []),
        failure_excerpt: ci_failure_excerpt(Map.get(result, :failures, []))
      }
      |> Sanitizer.scrub()
      |> then(fn payload ->
        Map.put(
          payload,
          :message,
          ci_terminal_message(
            outcome,
            Map.get(payload, :checks, []),
            Map.get(payload, :failure_excerpt)
          )
        )
      end)

    case Publisher.publish(topic, payload,
           issue_number: target,
           bypass_contamination: true,
           dedup_key: ci_event_dedup_key(target, outcome, Map.get(result, :head_sha))
         ) do
      {:ok, id, _subscribers} ->
        event = Map.merge(payload, %{id: id, topic: topic})
        OperatorMessages.enqueue_event_digest_item(state, target, [event], event)

      :deduped ->
        state

      :filtered ->
        Logger.warning("CI terminal event unexpectedly filtered: issue=#{target} topic=#{topic}")
        state
    end
  end

  @doc false
  @spec ensure_ci_terminal_subscription(State.t(), term()) :: term()
  def ensure_ci_terminal_subscription(state, issue) do
    case CiLifecycle.ci_target_for_issue(issue) do
      target when is_binary(target) ->
        :ok = UniversalSubscriptions.attach(target)
        state

      _ ->
        state
    end
  end

  defp ci_event_dedup_key(target, outcome, head_sha)
       when is_binary(target) and is_atom(outcome) and is_binary(head_sha) do
    {"ci", Atom.to_string(outcome), target <> ":" <> head_sha}
  end

  defp ci_event_dedup_key(_target, _outcome, _head_sha), do: nil

  defp ci_failure_excerpt(failures) when is_list(failures) do
    Enum.find_value(failures, fn
      %{excerpt: excerpt} when is_binary(excerpt) and excerpt != "" -> excerpt
      _ -> nil
    end)
  end

  defp ci_failure_excerpt(_failures), do: nil

  defp ci_terminal_message(:passed, _failures, _failure_excerpt),
    do: "CI passed for the current PR head"

  defp ci_terminal_message(:failed, failures, failure_excerpt) do
    names =
      failures
      |> Enum.map(&Map.get(&1, :name))
      |> Enum.filter(&is_binary/1)
      |> Enum.join(", ")

    message =
      if names == "", do: "CI failed for the current PR head", else: "CI failed: " <> names

    if is_binary(failure_excerpt) and failure_excerpt != "" do
      message <>
        ". Failure excerpt: " <>
        String.slice(failure_excerpt, 0, @ci_failure_excerpt_message_max)
    else
      message
    end
  end
end
