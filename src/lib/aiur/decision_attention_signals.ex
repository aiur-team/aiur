defmodule Aiur.DecisionAttentionSignals do
  @moduledoc false

  alias Aiur.{AlertFeed, Alerts, Decision}

  @open_statuses [:open, :deferred]

  @spec suspicious_classification?(Decision.t()) :: boolean()
  def suspicious_classification?(%Decision{} = decision) do
    decision.authority == :human_required and
      decision.reversibility == :reversible and
      decision.options != [] and
      Enum.all?(decision.options, &(normalize_risk(Map.get(&1, :risk)) == "low"))
  end

  @spec sync_classification(Decision.t(), keyword()) :: :ok | {:error, term()}
  def sync_classification(%Decision{} = decision, opts \\ []) do
    classification_topic = classification_topic(decision)
    stale_topic = stale_topic(decision)
    states = Keyword.get_lazy(opts, :condition_states, fn -> condition_states([classification_topic, stale_topic], opts) end)
    opts = Keyword.put(opts, :condition_states, states)

    classification_result =
      if suspicious_classification?(decision) and decision.decision_status in @open_statuses do
        open_once(
          classification_topic,
          "Command #{decision.decision_id} is human-required although every option is low-risk and the requested action is reversible.",
          decision,
          "Review the request classification; routine reversible operations should normally be supervisor_allowed.",
          opts
        )
      else
        resolve_if_open(classification_topic, "Command classification warning resolved", decision, opts)
      end

    stale_result =
      if decision.blocking and decision.decision_status in @open_statuses do
        :ok
      else
        resolve_if_open(stale_topic, "Blocking Command age warning resolved", decision, opts)
      end

    merge_results(classification_result, stale_result)
  end

  @doc false
  @spec reconcile([Decision.t()], [Decision.t()], [Decision.t()], DateTime.t(), keyword()) :: :ok | {:error, term()}
  def reconcile(decisions, stale_decisions, expired_decisions, now, opts \\ []) do
    topics =
      Enum.flat_map(decisions, &[classification_topic(&1), stale_topic(&1)]) ++
        Enum.map(expired_decisions, &expired_topic/1)

    opts = Keyword.put(opts, :condition_states, condition_states(topics, opts))

    classification_result = sync_classifications(decisions, opts)
    stale_result = sync_expiries(stale_decisions, :stale_blocking, now, opts)
    expired_result = sync_expiries(expired_decisions, :expired_unanswerable, now, opts)

    classification_result
    |> merge_results(stale_result)
    |> merge_results(expired_result)
  end

  @doc false
  @spec sync_classifications([Decision.t()], keyword()) :: :ok | {:error, term()}
  def sync_classifications(decisions, opts \\ []) when is_list(decisions) do
    topics = Enum.flat_map(decisions, &[classification_topic(&1), stale_topic(&1)])
    opts = Keyword.put_new_lazy(opts, :condition_states, fn -> condition_states(topics, opts) end)

    Enum.reduce(decisions, :ok, &merge_results(&2, sync_classification(&1, opts)))
  end

  @doc false
  @spec sync_expiries([Decision.t()], :stale_blocking | :expired_unanswerable, DateTime.t(), keyword()) ::
          :ok | {:error, term()}
  def sync_expiries(decisions, signal, now, opts \\ []) when is_list(decisions) do
    topics = Enum.map(decisions, &expiry_topic(&1, signal))
    opts = Keyword.put_new_lazy(opts, :condition_states, fn -> condition_states(topics, opts) end)

    Enum.reduce(decisions, :ok, &merge_results(&2, sync_expiry(&1, signal, now, opts)))
  end

  @spec sync_expiry(Decision.t(), :stale_blocking | :expired_unanswerable, DateTime.t(), keyword()) ::
          :ok | {:error, term()}
  def sync_expiry(decision, signal, now, opts \\ [])

  def sync_expiry(%Decision{} = decision, :stale_blocking, now, opts) do
    age_hours = max(div(DateTime.diff(now, decision.created_at, :second), 3_600), 0)

    open_once(
      stale_topic(decision),
      "Blocking Command #{decision.decision_id} has remained unanswered for #{age_hours} hours.",
      decision,
      "A blocking Command older than one day indicates stale context, poor visibility, or an incorrect authority classification.",
      opts
    )
  end

  def sync_expiry(%Decision{} = decision, :expired_unanswerable, _now, opts) do
    open_once(
      expired_topic(decision),
      "Executor-unanswerable Command #{decision.decision_id} expired without a decision.",
      decision,
      "The Command expired with no answer while its authority or reversibility kept it outside the Executor's floor; inspect repeated expiries and the upstream classification.",
      opts
    )
  end

  defp open_once(topic, message, decision, reason, opts) do
    if condition_state(topic, opts) == :firing do
      :ok
    else
      emit(topic, message, decision, reason, true, "warning", opts)
    end
  end

  defp resolve_if_open(topic, message, decision, opts) do
    if condition_state(topic, opts) == :firing do
      emit(topic <> ".resolved", message, decision, message, false, "info", opts)
    else
      :ok
    end
  end

  defp condition_state(topic, opts) do
    case Keyword.fetch(opts, :condition_states) do
      {:ok, states} -> Map.get(states, topic, :unknown)
      :error -> Keyword.get(opts, :condition_state_fun, &AlertFeed.condition_state/1).(topic)
    end
  end

  defp condition_states(topics, opts) do
    case Keyword.get(opts, :condition_states_fun) do
      fun when is_function(fun, 1) ->
        fun.(topics)

      nil ->
        case Keyword.get(opts, :condition_state_fun) do
          fun when is_function(fun, 1) -> Map.new(topics, &{&1, fun.(&1)})
          nil -> AlertFeed.condition_states(topics)
        end
    end
  end

  defp emit(topic, message, decision, reason, needs_attention, severity, opts) do
    Keyword.get(opts, :alert_fun, &Alerts.emit_system/2).(
      topic,
      issue: decision.ticket.identifier,
      message: message,
      reason: reason,
      needs_attention: needs_attention,
      severity: severity
    )
  end

  defp merge_results(:ok, :ok), do: :ok
  defp merge_results({:error, _reason} = error, _other), do: error
  defp merge_results(_first, {:error, _reason} = error), do: error

  defp classification_topic(decision), do: attention_topic(decision, "decision-classification")
  defp stale_topic(decision), do: attention_topic(decision, "decision-stale")
  defp expired_topic(decision), do: attention_topic(decision, "decision-expired-unanswerable")

  defp expiry_topic(decision, :stale_blocking), do: stale_topic(decision)
  defp expiry_topic(decision, :expired_unanswerable), do: expired_topic(decision)

  defp attention_topic(decision, kind) do
    digest = :sha256 |> :crypto.hash(decision.decision_id) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "ticket.#{decision.ticket.identifier}.agent.attention.#{kind}-#{digest}"
  end

  defp normalize_risk(risk) when is_binary(risk), do: risk |> String.trim() |> String.downcase()
  defp normalize_risk(_risk), do: nil
end
