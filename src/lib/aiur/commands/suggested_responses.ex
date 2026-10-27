defmodule Aiur.Commands.SuggestedResponses do
  @moduledoc false

  alias Aiur.Commands.RequestContent
  alias Aiur.Commands.Requester
  alias Aiur.Config
  alias Aiur.Signal

  @spec validate(Aiur.Decision.t(), keyword()) :: :ok | {:error, term()}
  def validate(decision, opts) do
    case check(decision, opts) do
      {:warn, reason} ->
        if Config.decisions_require_suggested_responses?(),
          do: {:error, {:decision_invalid, {:suggested_responses, reason}}},
          else: :ok

      :ok ->
        :ok
    end
  end

  @spec warn_once(term(), map(), keyword()) :: term()
  def warn_once({:reply, {:ok, %{status: :accepted, decision: decision}}, _state} = result, previous, opts) do
    with false <- Map.has_key?(previous.current, decision.decision_id),
         {:warn, reason} <- check(decision, opts) do
      alert_fun = Keyword.get(opts, :alert_fun, &Signal.agent_alert/3)

      alert_fun.(
        "ticket.#{decision.ticket.identifier}.agent.decision.suggested-responses",
        "Command #{decision.decision_id}: #{reason}",
        severity: :info,
        issue: decision.ticket.identifier,
        dedup_key: {:suggested_responses, decision.decision_id},
        needs_attention: false,
        reason: "suggested_responses:#{reason}",
        exchange_payload: %{decision_id: decision.decision_id, suggested_response_reason: reason}
      )
    end

    result
  end

  def warn_once(result, _previous, _opts), do: result

  defp check(decision, opts) do
    RequestContent.suggested_response_check(decision, Keyword.get(opts, :origin, Requester.origin(decision)))
  end
end
