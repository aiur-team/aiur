defmodule Aiur.Orchestrator.PriorityControl do
  @moduledoc """
  Applies operator-requested dispatch priority through the tracker-backed
  `priority:*` labels.

  The tracker remains durable authority for the value. Once a write succeeds,
  the orchestrator immediately refreshes its in-memory copies so the dashboard
  and dispatch policy observe the same priority before the next poll.
  """

  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator.{State, StatusReport}

  @prioritized_label "priority:1"

  @spec prioritize_agent(String.t()) :: {:ok, :prioritized | :already_prioritized} | {:error, term()}
  def prioritize_agent(identifier), do: prioritize_agent(Aiur.Orchestrator, identifier)

  @spec prioritize_agent(GenServer.server(), String.t()) :: {:ok, :prioritized | :already_prioritized} | {:error, term()}
  def prioritize_agent(server, identifier) when is_binary(identifier), do: control_api_call(server, {:prioritize_agent, identifier})

  @spec deprioritize_agent(String.t()) :: {:ok, :deprioritized | :already_deprioritized} | {:error, term()}
  def deprioritize_agent(identifier), do: deprioritize_agent(Aiur.Orchestrator, identifier)

  @spec deprioritize_agent(GenServer.server(), String.t()) :: {:ok, :deprioritized | :already_deprioritized} | {:error, term()}
  def deprioritize_agent(server, identifier) when is_binary(identifier), do: control_api_call(server, {:deprioritize_agent, identifier})

  @doc false
  @spec prioritize_agent_call(State.t(), String.t(), keyword()) ::
          {:reply, {:ok, :prioritized | :already_prioritized} | {:error, term()}, State.t()}
  def prioritize_agent_call(%State{} = state, identifier, opts \\ []) when is_binary(identifier) do
    change_priority(state, identifier, :prioritized, opts)
  end

  @doc false
  @spec deprioritize_agent_call(State.t(), String.t(), keyword()) ::
          {:reply, {:ok, :deprioritized | :already_deprioritized} | {:error, term()}, State.t()}
  def deprioritize_agent_call(%State{} = state, identifier, opts \\ []) when is_binary(identifier) do
    change_priority(state, identifier, :deprioritized, opts)
  end

  defp change_priority(state, identifier, target, opts) do
    with {:ok, %Issue{} = issue} <- issue_by_identifier(state, identifier),
         {:ok, result, updated_issue} <- persist_priority(issue, target, opts) do
      state = replace_issue(state, updated_issue)
      notify_dashboard = Keyword.get(opts, :notify_dashboard_fun, &StatusReport.notify_dashboard/1)
      :ok = notify_dashboard.(state)
      {:reply, {:ok, result}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp issue_by_identifier(%State{} = state, identifier) do
    case Enum.find(state.last_polled_issues, fn {_issue_id, issue} -> issue.identifier == identifier or issue.id == identifier end) do
      {_issue_id, %Issue{} = issue} -> {:ok, issue}
      nil -> {:error, :unknown_issue}
    end
  end

  defp persist_priority(issue, :prioritized, opts) do
    priority_labels = priority_labels(issue.labels)

    if priority_labels == [@prioritized_label] do
      {:ok, :already_prioritized, issue}
    else
      with :ok <- remove_priority_labels(issue.id, priority_labels, opts),
           :ok <- add_label(issue.id, @prioritized_label, opts) do
        {:ok, :prioritized, with_priority(issue, @prioritized_label)}
      end
    end
  end

  defp persist_priority(issue, :deprioritized, opts) do
    case priority_labels(issue.labels) do
      [] ->
        {:ok, :already_deprioritized, issue}

      priority_labels ->
        with :ok <- remove_priority_labels(issue.id, priority_labels, opts) do
          {:ok, :deprioritized, without_priority(issue)}
        end
    end
  end

  defp remove_priority_labels(issue_id, labels, opts) do
    remove_label = Keyword.get(opts, :remove_label_fun, &Tracker.remove_label/2)

    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case remove_label.(issue_id, label) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_label(issue_id, label, opts) do
    add_label = Keyword.get(opts, :add_label_fun, &Tracker.add_label/2)
    add_label.(issue_id, label)
  end

  defp replace_issue(state, issue) do
    last_polled_issues = Map.put(state.last_polled_issues, issue.id, issue)

    running =
      case Map.get(state.running, issue.id) do
        %{issue: _} = entry -> Map.put(state.running, issue.id, Map.put(entry, :issue, issue))
        _ -> state.running
      end

    retry_attempts =
      case Map.get(state.retry_attempts, issue.id) do
        retry when is_map(retry) -> Map.put(state.retry_attempts, issue.id, Map.put(retry, :priority, issue.priority))
        _ -> state.retry_attempts
      end

    %{state | last_polled_issues: last_polled_issues, running: running, retry_attempts: retry_attempts}
  end

  defp with_priority(issue, label) do
    %{issue | priority: 1, labels: priority_labels_removed(issue.labels) ++ [label]}
  end

  defp without_priority(issue), do: %{issue | priority: nil, labels: priority_labels_removed(issue.labels)}

  defp priority_labels(labels), do: Enum.filter(labels || [], &priority_label?/1)
  defp priority_labels_removed(labels), do: Enum.reject(labels || [], &priority_label?/1)
  defp priority_label?(label), do: is_binary(label) and String.match?(label, ~r/^priority:\d+$/)

  defp control_api_call(server, request) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, 5_000)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end
end
