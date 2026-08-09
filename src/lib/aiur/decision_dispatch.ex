defmodule Aiur.DecisionDispatch do
  @moduledoc """
  Renders and sends one durable Decision answer through OperatorMessages.

  This module never persists state. `Aiur.DecisionStore` owns the outbox
  ordering and only calls `dispatch/2` after the answer event and current
  projection are durable.
  """

  alias Aiur.{Decision, DecisionAnswer, DecisionRevisionDispatch}
  alias Aiur.Orchestrator.OperatorMessages

  @max_message_chars 7_800

  @doc "Maximum rendered body accepted from this dispatcher."
  @spec max_message_chars() :: pos_integer()
  def max_message_chars, do: @max_message_chars

  @doc "Send an answered Decision through the correlated Executor-message path."
  @spec dispatch(Decision.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(decision, opts \\ [])

  def dispatch(%Decision{revisions: [_revision | _]} = decision, opts) do
    DecisionRevisionDispatch.dispatch(decision, opts)
  end

  def dispatch(%Decision{answer: %DecisionAnswer{} = answer} = decision, opts) do
    attempt_id = Keyword.fetch!(opts, :attempt_id)
    retry_failed = Keyword.get(opts, :retry_failed, false)
    server = Keyword.get(opts, :operator_messages, Aiur.Orchestrator)
    send_fun = Keyword.get(opts, :send_fun, &OperatorMessages.send_correlated_operator_message/3)

    correlation = %{
      decision_id: decision.decision_id,
      decision_version: answer.decision_version,
      action_id: answer.action_id,
      attempt_id: attempt_id,
      actor: answer.actor,
      answer_content_hash: answer.content_hash
    }

    payload = %{
      kind: :text,
      body: render(decision),
      # A Decision answer is authoritative input that can change the work an
      # active agent is about to commit or hand off. Interrupt capable
      # backends should steer immediately; other backends retain the durable
      # queue item for the next safe checkpoint.
      delivery_policy: :interrupt,
      fallback: :queue_next,
      action_id: answer.action_id,
      correlation: correlation,
      retry_failed: retry_failed
    }

    send_fun.(server, decision.ticket.identifier, payload)
  end

  def dispatch(%Decision{}, _opts), do: {:error, :answer_missing}

  @doc "Render a bounded, human-readable envelope while preserving lifecycle instructions."
  @spec render(Decision.t()) :: String.t()
  def render(%Decision{answer: %DecisionAnswer{} = answer} = decision) do
    header = """
    Durable Executor answer for ticket #{decision.ticket.identifier}
    Decision: #{decision.decision_id}
    Request version: #{answer.decision_version}
    Action: #{answer.action_id}
    Answered by: #{answer.actor.kind}:#{answer.actor.id || "unknown"}
    Question: #{decision.question}
    """

    response = response_text(decision, answer)
    rationale = if answer.rationale, do: "\nRationale: #{answer.rationale}\n", else: "\n"

    footer = """

    This answer is append-only and may be replayed after a retry or reconnect. Do not apply it twice.
    After observing it, emit `decision.acknowledged` with decision_id `#{decision.decision_id}`, action_id `#{answer.action_id}`, and expected_version #{answer.decision_version}.
    When the work is complete, emit `decision.resolved` with the same correlation fields.
    """

    bounded_join(header, response <> rationale, footer)
  end

  defp response_text(decision, %DecisionAnswer{selected_option_id: option_id}) when is_binary(option_id) do
    label =
      decision.options
      |> Enum.find(&(&1.id == option_id))
      |> case do
        nil -> "unknown option"
        option -> option.label
      end

    "Selected option `#{option_id}`: #{label}"
  end

  defp response_text(_decision, %DecisionAnswer{custom_response: response}) do
    "Custom response: #{response}"
  end

  defp bounded_join(header, content, footer) do
    available = max(@max_message_chars - String.length(header) - String.length(footer), 0)
    header <> String.slice(content, 0, available) <> footer
  end
end
