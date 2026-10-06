defmodule AiurWeb.OperatorControlCenter.AddAgentSubmission do
  @moduledoc false

  alias Aiur.GitHub.StatePolicy
  alias Aiur.Tracker
  alias AiurWeb.Endpoint
  alias AiurWeb.OperatorControlCenter.AgentRoutingPreview

  @spec run(map()) :: map()
  def run(modal) do
    case fetch_issue(modal.identifier) do
      {:ok, [issue]} -> apply_current(modal, Map.get(issue, :labels, modal.labels))
      other -> %{added: [], removed: [], labels: modal.labels, error: {:current_ticket_unavailable, other}, authorization: :unknown}
    end
  end

  defp apply_current(modal, labels) do
    plan = AgentRoutingPreview.plan(modal.selection, labels)
    mutations = Enum.map(plan.remove, &{:remove_label, &1}) ++ Enum.map(plan.add, &{:add_label, &1})
    initial = %{added: [], removed: [], labels: labels, error: nil, authorization: :unknown}
    result = Enum.reduce_while(mutations, initial, &mutate(modal.identifier, &1, &2))
    if result.error, do: result, else: Map.merge(result, admission(modal.identifier))
  end

  @spec labels(map(), [String.t()]) :: [String.t()]
  def labels(result, original), do: Enum.uniq((Map.get(result, :labels, original) -- result.removed) ++ result.added)

  @spec message(map()) :: String.t()
  def message(%{error: {:submission_exit, _}}),
    do: "Submission interrupted; some labels may already have changed. Check the ticket before retrying."

  def message(%{error: error} = result) when not is_nil(error) do
    "Applied #{Enum.join(result.added, ", ")}; removed #{Enum.join(result.removed, ", ")}. " <>
      "Stopped: #{inspect(error)}. Retry applies only the remaining changes."
  end

  def message(%{authorization: :authorized, state: "todo"}),
    do: "Labels saved. Waiting for an agent to start."

  def message(%{authorization: :authorized, state: state}) when is_binary(state),
    do: "Labels saved. Ticket remains #{state}."

  def message(%{authorization: :authorized}),
    do: "Labels saved. Current ticket state is unavailable; Check admission to retry."

  def message(%{authorization: :denied}),
    do: "Labels saved; dispatch authorization declined. An allowed GitHub operator must remove and reapply the ticket's trigger label using their own account, then Check admission."

  def message(%{authorization: :deferred}),
    do: "Labels saved. Authorization check unavailable. No admission is confirmed; Check admission to retry."

  def message(_result),
    do: "Labels saved. Admission could not be confirmed; Check admission to retry."

  defp mutate(identifier, {action, label}, result) do
    fun = Endpoint.config(:add_agent_fun) || (&apply(Tracker, &3, [&1, &2]))

    case safe_call(fn -> call_label(fun, identifier, label, action) end) do
      :ok -> record(result, action, label)
      {:ok, _} -> record(result, action, label)
      {:error, reason} -> {:halt, %{result | error: reason}}
      other -> {:halt, %{result | error: {:unexpected_tracker_response, other}}}
    end
  end

  defp record(result, action, label) do
    key = if action == :add_label, do: :added, else: :removed
    {:cont, Map.update!(result, key, &(&1 ++ [label]))}
  end

  defp call_label(fun, identifier, label, action) when is_function(fun, 3), do: fun.(identifier, label, action)
  defp call_label(fun, identifier, label, _action) when is_function(fun, 2), do: fun.(identifier, label)

  defp admission(identifier) do
    case fetch_issue(identifier) do
      {:ok, [issue]} -> %{authorization: Map.get(issue, :dispatch_authorization, :unknown), state: observed_state(issue)}
      _ -> %{authorization: :unknown, state: nil}
    end
  end

  defp observed_state(%{state: state}) when is_binary(state) and state != "", do: StatePolicy.normalize_state(state)
  defp observed_state(_issue), do: nil

  defp fetch_issue(identifier) do
    fun = Endpoint.config(:add_agent_verify_fun) || (&Tracker.fetch_issue_states_by_ids/1)
    safe_call(fn -> fun.([identifier]) end)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:tracker_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
