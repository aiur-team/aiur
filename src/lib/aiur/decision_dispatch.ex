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

  @doc "Render a concise, product-focused answer envelope for the agent."
  @spec render(Decision.t()) :: String.t()
  def render(%Decision{answer: %DecisionAnswer{} = answer} = decision) do
    response = response_text(decision, answer)
    rationale = if answer.rationale, do: "Rationale: #{answer.rationale}", else: nil
    lifecycle = lifecycle_instruction()

    [response, rationale, lifecycle]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> bound(@max_message_chars)
  end

  # The agent is told only what to do next, in product terms. Correlations,
  # versions and the ticket identity live in the queue payload, not the prose,
  # so the operator's answer reads the way it was written.
  defp lifecycle_instruction do
    "After applying this, emit `decision.acknowledged` and, when the work is done, `decision.resolved`."
  end

  defp bound(body, limit) when byte_size(body) <= limit, do: body
  defp bound(body, limit), do: String.slice(body, 0, limit)

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
end
