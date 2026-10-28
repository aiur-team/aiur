defmodule Aiur.Orchestrator.RateLimitFallbackTransition do
  @moduledoc false

  require Logger
  alias Aiur.Orchestrator.{State, TrackerTasks}

  @spec prune(State.t()) :: State.t()
  def prune(state), do: %{state | fallback_backoff: Map.take(state.fallback_backoff, Map.keys(state.running))}

  @spec deferred?(State.t(), String.t(), keyword()) :: boolean()
  def deferred?(state, id, opts) do
    {_attempts, next_at} = Map.get(state.fallback_backoff, id, {0, now_ms(opts)})
    next_at > now_ms(opts) or TrackerTasks.running?(state, {:fallback_labels, id})
  end

  @spec run(map(), :engage | :revert, String.t(), String.t(), function()) :: {State.t(), boolean()}
  def run(context, transition, backend, marker, redispatch) do
    next =
      TrackerTasks.run(
        context.state,
        {:fallback_labels, context.issue.id},
        fn ->
          write(context, transition, "model:#{backend}", marker)
        end,
        fn current, result -> apply_result(current, result, context, transition, redispatch) end
      )

    # Async writes reserve this tick's slot; pending/backed-off tickets skip later ticks.
    {next, TrackerTasks.owner?(context.state) or not Map.has_key?(next.fallback_backoff, context.issue.id)}
  end

  defp write(context, :engage, routing, marker), do: write_pair(context, :add, marker, routing)
  defp write(context, :revert, routing, marker), do: write_pair(context, :remove, routing, marker)

  defp write_pair(context, action, first, second) do
    write = if action == :add, do: context.add_label, else: context.remove_label
    undo = if action == :add, do: context.remove_label, else: context.add_label

    case write.(context.identifier, first) do
      :ok ->
        case write.(context.identifier, second) do
          :ok -> :ok
          {:error, reason} -> {:error, reason, undo.(context.identifier, first)}
        end

      {:error, reason} ->
        {:error, reason, :not_needed}
    end
  end

  defp apply_result(current, result, context, transition, redispatch) do
    entry = Map.get(current.running, context.issue.id)

    if TrackerTasks.same_runner?(entry, context.running_entry) do
      finish(current, result, context, transition, redispatch)
    else
      current
    end
  end

  defp finish(current, :ok, context, transition, redispatch) do
    Logger.info("Rate-limit fallback #{transition} labels persisted; re-dispatching: #{log_context(context)}")
    current = %{current | fallback_backoff: Map.delete(current.fallback_backoff, context.issue.id)}
    redispatch.(current, Map.fetch!(current.running, context.issue.id), context.relabeled, context.opts)
  end

  defp finish(current, result, context, transition, _redispatch) do
    {reason, rollback} = failure_details(result)
    Logger.error("Rate-limit fallback #{transition} failed: #{log_context(context)} reason=#{inspect(reason)} rollback=#{inspect(rollback)}")
    {attempts, _deadline} = Map.get(current.fallback_backoff, context.issue.id, {0, 0})
    attempts = attempts + 1
    delay = min((current.poll_interval_ms || Aiur.PollCadence.base_interval_ms(class: :dispatch)) * Integer.pow(2, min(attempts - 1, 20)), 600_000)
    backoff = Map.put(current.fallback_backoff, context.issue.id, {attempts, now_ms(context.opts) + delay})
    if attempts == 3, do: alert(context, reason)
    %{current | fallback_backoff: backoff}
  end

  defp failure_details({:error, reason, rollback}), do: {reason, rollback}
  defp failure_details({:error, reason}), do: {reason, :unknown}
  defp failure_details(result), do: {{:unexpected_outcome, result}, :unknown}

  defp alert(context, reason) do
    emit = Keyword.get(context.opts, :emit_alert_fun, &Aiur.Signal.alert/2)

    emit.("ticket.#{context.issue.identifier}.agent.rate_limit_fallback_write_failed",
      issue: context.issue,
      reason: "Fallback label writes failed three times: #{inspect(reason)}",
      needs_attention: true,
      severity: "warning"
    )
  end

  defp log_context(context),
    do: "#{State.issue_context(context.issue)} session_id=#{State.running_entry_session_id(context.running_entry)}"

  defp now_ms(opts), do: Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
end
