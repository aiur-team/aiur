defmodule Aiur.AgentRunner.ToolCoordination do
  @moduledoc false

  alias Aiur.AgentRunner.CiWaitTransition
  alias Aiur.Events.SubscriptionStore

  @spec declare_blocker_for_issue(map(), term(), map()) :: term()
  def declare_blocker_for_issue(issue, blocker_number, coordination) do
    case issue_number_of(issue) do
      nil ->
        {:error, :no_issue_number}

      current ->
        admit(
          coordination.enqueue,
          ticket_coordination_key(issue),
          fn -> declare_and_reconcile(current, blocker_number, coordination) end,
          coordination_operation_opts(issue)
        )
    end
  end

  # Serialized on the same per-ticket coordination key as blocker declaration,
  # so an agent's own state write cannot interleave with another mutation of the
  # same ticket. The write itself is a swap: add the target label, then remove
  # every other `agent:*` state label present on the freshly fetched body.
  @spec set_ticket_state_for_issue(map(), String.t(), map()) :: term()
  def set_ticket_state_for_issue(issue, state_name, coordination) do
    case tracker_issue_id(issue) do
      nil ->
        {:error, :no_issue_number}

      issue_id ->
        coordination.run.(
          ticket_coordination_key(issue),
          fn -> write_ticket_state(coordination, issue_id, state_name) end,
          coordination_operation_opts(issue)
        )
    end
  end

  defp write_ticket_state(coordination, issue_id, state_name) do
    CiWaitTransition.write(coordination, issue_id, state_name)
  end

  defp tracker_issue_id(issue) do
    case Map.get(issue, :id) || Map.get(issue, :identifier) do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      _ -> nil
    end
  end

  @spec unblock_for_issue(map(), term(), map()) :: term()
  def unblock_for_issue(issue, blocker_number, coordination) do
    case issue_number_of(issue) do
      nil ->
        {:error, :no_issue_number}

      current ->
        coordination.run.(
          ticket_coordination_key(issue),
          fn -> coordination.unblock_dependency.(current, blocker_number) end,
          coordination_operation_opts(issue)
        )
    end
  end

  @spec ticket_coordination_key(map()) :: tuple()
  def ticket_coordination_key(issue), do: {:ticket, issue_identifier(issue) || issue_number_of(issue)}

  @spec coordination_operation_opts(map()) :: keyword()
  def coordination_operation_opts(issue) do
    [
      operation_timeout: :infinity,
      log_context: %{
        issue_id: Map.get(issue, :id),
        issue_identifier: Map.get(issue, :identifier)
      }
    ]
  end

  defp admit(enqueue, key, operation, opts) do
    case enqueue.(key, operation, opts) do
      :pending -> {:ok, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp declare_and_reconcile(current, blocker, coordination) do
    case safe_coordination_call(coordination.subscribe_blocker, [current, blocker]) do
      :ok ->
        case safe_coordination_call(coordination.declare_dependency, [current, blocker]) do
          {:ok, _result} -> :ok
          {:error, reason} -> reconcile_declaration(current, blocker, reason, coordination)
          other -> reconcile_declaration(current, blocker, {:unexpected, other}, coordination)
        end

      {:error, reason} ->
        reconcile_subscription_failure(current, blocker, reason, coordination)

      other ->
        reconcile_subscription_failure(current, blocker, {:unexpected, other}, coordination)
    end
  end

  defp safe_coordination_call(function, arguments) do
    apply(function, arguments)
  rescue
    error -> {:error, {:coordination_call_error, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:coordination_call_exit, reason}}
  end

  defp reconcile_declaration(current, blocker, declaration_error, coordination) do
    coordination.dependency_present
    |> safe_coordination_call([current, blocker])
    |> reconcile_declaration_state(current, blocker, declaration_error, coordination)
  end

  defp reconcile_subscription_failure(current, blocker, subscription_error, coordination) do
    coordination.dependency_present
    |> safe_coordination_call([current, blocker])
    |> reconcile_subscription_state(current, blocker, subscription_error, coordination)
  end

  defp reconcile_declaration_state({:ok, true}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.subscribe_blocker, [current, blocker])
    normalize_reconcile_result(result, :blocker_reconcile_subscription_failed, error)
  end

  defp reconcile_declaration_state({:ok, false}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.unsubscribe_blocker, [current, blocker])
    normalize_cleanup_result(result, :blocker_declaration_failed, :blocker_declaration_cleanup_failed, error)
  end

  defp reconcile_declaration_state({:error, reason}, _current, _blocker, error, _coordination),
    do: {:error, {:blocker_reconcile_inconclusive, error, reason}}

  defp reconcile_subscription_state({:ok, true}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.subscribe_blocker, [current, blocker])
    normalize_reconcile_result(result, :blocker_subscription_retry_failed, error)
  end

  defp reconcile_subscription_state({:ok, false}, current, blocker, error, coordination) do
    result = safe_coordination_call(coordination.unsubscribe_blocker, [current, blocker])
    normalize_cleanup_result(result, :blocker_subscription_failed, :blocker_subscription_cleanup_failed, error)
  end

  defp reconcile_subscription_state({:error, reason}, _current, _blocker, error, _coordination),
    do: {:error, {:blocker_subscription_reconcile_inconclusive, error, reason}}

  defp normalize_reconcile_result(:ok, _failure, _original_error), do: :ok

  defp normalize_reconcile_result({:error, reason}, failure, original_error),
    do: {:error, {failure, original_error, reason}}

  defp normalize_reconcile_result(other, failure, original_error),
    do: {:error, {failure, original_error, {:unexpected, other}}}

  defp normalize_cleanup_result(:ok, failure, _cleanup_failure, original_error),
    do: {:error, {failure, original_error}}

  defp normalize_cleanup_result({:error, reason}, _failure, cleanup_failure, original_error),
    do: {:error, {cleanup_failure, original_error, reason}}

  defp normalize_cleanup_result(other, _failure, cleanup_failure, original_error),
    do: {:error, {cleanup_failure, original_error, {:unexpected, other}}}

  @spec issue_number_of(map()) :: String.t() | integer() | nil
  def issue_number_of(issue) do
    case Map.get(issue, :number) || Map.get(issue, :identifier) do
      n when is_integer(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end
  end

  @spec subscribe_for_issue(map(), String.t()) :: term()
  def subscribe_for_issue(issue, pattern) do
    case issue_identifier(issue) do
      nil ->
        {:error, :no_issue_identifier}

      id ->
        :ok = SubscriptionStore.attach(id)
        SubscriptionStore.add_subscription(id, pattern, "manual:agent")
    end
  end

  @spec unsubscribe_for_issue(map(), String.t()) :: term()
  def unsubscribe_for_issue(issue, pattern) do
    case issue_identifier(issue) do
      nil -> {:error, :no_issue_identifier}
      id -> SubscriptionStore.remove_subscription(id, pattern)
    end
  end

  @spec issue_identifier(map()) :: String.t() | nil
  def issue_identifier(issue) do
    cond do
      is_binary(Map.get(issue, :id)) -> issue.id
      is_binary(Map.get(issue, :identifier)) -> issue.identifier
      true -> nil
    end
  end
end
