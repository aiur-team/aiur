defmodule Aiur.DecisionStore.Audit do
  @moduledoc false

  require Logger

  alias Aiur.Decision
  alias Aiur.DecisionAnswer
  alias Aiur.DecisionEvent
  alias Aiur.DecisionProjection
  alias Aiur.DecisionPubSub
  alias Aiur.DecisionRevision
  alias Aiur.DecisionStore.Answers
  alias Aiur.Events.Publisher

  @recent_audit_limit 50
  @system_follow_up_actor %{kind: :system, id: "decision-store"}

  @spec recent_limit() :: pos_integer()
  def recent_limit, do: @recent_audit_limit

  @spec system_actor() :: map()
  def system_actor, do: @system_follow_up_actor

  @spec notify(term(), term(), term()) :: term()
  def notify(decision, event_id, state) do
    topic = "ticket.#{decision.ticket.identifier}.agent.decision.requested"
    payload = DecisionProjection.to_json_safe(decision)

    try do
      Publisher.publish_persisted(topic, payload, event_id, digest_source: :orchestrator)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_publisher_failed error=#{Exception.message(error)}")
    end

    notify_requested_executor(decision, state, :executor_request_publisher)

    try do
      DecisionPubSub.broadcast_changed(decision.decision_id, decision.version)
    rescue
      error -> Logger.warning("aiur_decision_store phase=notify_pubsub_failed error=#{Exception.message(error)}")
    end

    :ok
  end

  @spec notify_requested_executor(term(), term(), term(), term()) :: term()
  def notify_requested_executor(decision, state, publisher_key, attempt \\ 0) do
    case state[publisher_key].(decision) do
      {:ok, _id, _subscribers} ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_decision_store phase=executor_request_notification_failed reason=#{inspect(reason)}")
        schedule_executor_request_retry(decision, state, attempt)
    end
  rescue
    error ->
      Logger.warning("aiur_decision_store phase=executor_request_notification_failed error=#{Exception.message(error)}")
      schedule_executor_request_retry(decision, state, attempt)
  catch
    :exit, reason ->
      Logger.warning("aiur_decision_store phase=executor_request_notification_failed exit=#{inspect(reason)}")
      schedule_executor_request_retry(decision, state, attempt)
  end

  # Bounded exactly like every sibling retry path (`schedule_append_retry`,
  # `schedule_transient_retry`): once the configured delay ladder is exhausted
  # the store gives up rather than reconciling the whole journal forever.
  @spec schedule_executor_request_retry(term(), term(), term()) :: term()
  def schedule_executor_request_retry(decision, state, attempt) do
    case Enum.at(state.retry_delays_ms, attempt) do
      delay when is_integer(delay) and delay >= 0 ->
        state.dispatch_scheduler.(
          self(),
          {:retry_executor_request_notification, decision.decision_id, decision.version, attempt + 1},
          delay
        )

        :ok

      _exhausted ->
        Logger.warning(
          "aiur_decision_store phase=executor_request_notification_retry_exhausted " <>
            "decision_id=#{decision.decision_id} version=#{decision.version} attempts=#{attempt}"
        )

        :ok
    end
  end

  @spec recent_audit_payload(term(), term()) :: term()
  def recent_audit_payload(state, records) do
    Enum.reduce(records, %{records: records, contexts: %{}, actions: %{}, revisions: %{}}, fn record, payload ->
      case audit_identity(record) do
        {decision_id, version} ->
          payload
          |> put_audit_context(state, decision_id, version)
          |> put_audit_action(state, decision_id, audit_action_id(record))

        nil ->
          payload
      end
    end)
  end

  defp put_audit_context(payload, state, decision_id, version) do
    case Answers.request_version(state, decision_id, version) || Map.get(state.current, decision_id) do
      %Decision{} = decision ->
        context = %{
          version: decision.version,
          ticket: decision.ticket,
          question: decision.question,
          provenance: decision.provenance
        }

        contexts = Map.update(payload.contexts, decision_id, %{version => context}, &Map.put(&1, version, context))
        %{payload | contexts: contexts}

      _other ->
        payload
    end
  end

  defp put_audit_action(payload, _state, _decision_id, nil), do: payload

  defp put_audit_action(payload, state, decision_id, action_id) do
    action =
      state.current
      |> Map.get(decision_id)
      |> case do
        %Decision{answer: %DecisionAnswer{action_id: ^action_id} = answer} -> answer
        %Decision{revisions: revisions} -> Enum.find(revisions, &(&1.action_id == action_id))
        _other -> nil
      end

    case action do
      %DecisionAnswer{} = answer ->
        actions =
          Map.update(payload.actions, decision_id, %{action_id => answer}, &Map.put(&1, action_id, answer))

        %{payload | actions: actions}

      %DecisionRevision{} = revision ->
        actions =
          Map.update(payload.actions, decision_id, %{action_id => revision}, &Map.put(&1, action_id, revision))

        revisions =
          Map.update(payload.revisions, decision_id, %{action_id => revision}, &Map.put(&1, action_id, revision))

        %{payload | actions: actions, revisions: revisions}

      _other ->
        payload
    end
  end

  defp audit_identity(%DecisionEvent{decision_id: decision_id, decision_version: version}),
    do: {decision_id, version}

  defp audit_identity(%Decision{decision_id: decision_id, version: version}), do: {decision_id, version}
  defp audit_identity(_record), do: nil

  defp audit_action_id(%DecisionEvent{data: %DecisionRevision{action_id: action_id}}), do: action_id
  defp audit_action_id(%DecisionEvent{data: %{action_id: action_id}}), do: action_id
  defp audit_action_id(_record), do: nil

  @spec remember_recent_audit(term(), term()) :: term()
  def remember_recent_audit(records, event), do: Enum.take([event | records], @recent_audit_limit)
end
