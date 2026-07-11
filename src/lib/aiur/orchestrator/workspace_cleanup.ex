defmodule Aiur.Orchestrator.WorkspaceCleanup do
  @moduledoc """
  Owns orchestrator WorkspaceCleanup behavior.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Config, Issue, SessionHandle, Tracker, Workspace}
  alias Aiur.Orchestrator.{DispatchPolicy, RetryEngine, State, TrackerHealth}

  @spec cleanup_issue_workspace(binary() | term(), binary() | nil) :: :ok
  def cleanup_issue_workspace(identifier, worker_host \\ nil)

  def cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  @doc false
  @spec cleanup_terminal_issue_artifacts(binary() | term(), binary() | nil) :: :ok
  def cleanup_terminal_issue_artifacts(identifier, worker_host \\ nil)

  def cleanup_terminal_issue_artifacts(identifier, worker_host) when is_binary(identifier) do
    cleanup_issue_workspace(identifier, worker_host)
    clear_session_handle(identifier)
  end

  @doc false
  @spec clear_session_handle(binary() | term()) :: :ok
  def clear_session_handle(identifier) when is_binary(identifier), do: SessionHandle.clear(identifier)
  def clear_session_handle(_identifier), do: :ok

  @spec run_startup_todo_workspace_cleanup(State.t()) :: State.t()
  def run_startup_todo_workspace_cleanup(%State{} = state) do
    case ensure_terminal_workspace_cleanup_preflight(state) do
      {:ok, state} ->
        cleanup_todo_workspaces_after_preflight(state)

      {:skip, reason, state} ->
        Logger.debug("Skipping startup todo workspace cleanup: #{RetryEngine.format_retry_preflight_error(reason)}")

        state

      {:error, reason, state} ->
        Logger.warning("Skipping startup todo workspace cleanup: #{RetryEngine.format_retry_preflight_error(reason)}")

        state
    end
  end

  defp cleanup_todo_workspaces_after_preflight(%State{} = state) do
    case Tracker.fetch_issues_by_states(configured_todo_states(), quiet_auth_errors?: true) do
      {:ok, issues} ->
        issues
        |> Enum.filter(&todo_issue_for_startup_cleanup?/1)
        |> Enum.each(&cleanup_issue_workspace_for_issue/1)

        state

      {:error, reason} ->
        Logger.debug("Skipping startup todo workspace cleanup; failed to fetch todo issues: #{inspect(reason)}")

        state
    end
  end

  defp configured_todo_states do
    Config.settings!().tracker.active_states
    |> Enum.filter(&(DispatchPolicy.state_slug(&1) == "todo"))
    |> case do
      [] -> ["todo"]
      states -> states
    end
  end

  defp todo_issue_for_startup_cleanup?(%Issue{state: state}) do
    DispatchPolicy.state_slug(state) == "todo"
  end

  defp todo_issue_for_startup_cleanup?(_issue), do: false

  @spec run_terminal_workspace_cleanup(State.t()) :: State.t()
  def run_terminal_workspace_cleanup(%State{} = state) do
    case ensure_terminal_workspace_cleanup_preflight(state) do
      {:ok, state} ->
        cleanup_terminal_workspaces_after_preflight(state)

      {:skip, reason, state} ->
        Logger.debug("Skipping startup terminal workspace cleanup: #{RetryEngine.format_retry_preflight_error(reason)}")

        state

      {:error, reason, state} ->
        Logger.warning("Skipping startup terminal workspace cleanup: #{RetryEngine.format_retry_preflight_error(reason)}")

        state
    end
  end

  defp ensure_terminal_workspace_cleanup_preflight(%State{} = state) do
    case TrackerHealth.ensure_tracker_preflight(state) do
      {:error, reason, state}
      when reason in [:missing_linear_api_token, :missing_linear_project_slug] ->
        {:skip, reason, state}

      result ->
        result
    end
  end

  defp cleanup_terminal_workspaces_after_preflight(%State{} = state) do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states,
           quiet_auth_errors?: true
         ) do
      {:ok, issues} ->
        Enum.each(issues, &cleanup_terminal_issue_workspace/1)
        state

      {:error, reason} ->
        log_terminal_workspace_cleanup_fetch_skip(reason)

        state
    end
  end

  defp log_terminal_workspace_cleanup_fetch_skip(reason)
       when reason in [:missing_linear_api_token, :missing_linear_project_slug] do
    Logger.debug("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp log_terminal_workspace_cleanup_fetch_skip({:linear_api_status, 401} = reason) do
    Logger.debug("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp log_terminal_workspace_cleanup_fetch_skip({:linear_api_request, :missing_linear_api_token} = reason) do
    Logger.debug("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp log_terminal_workspace_cleanup_fetch_skip(reason) do
    Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
  end

  defp cleanup_terminal_issue_workspace(%Issue{identifier: identifier})
       when is_binary(identifier),
       do: cleanup_terminal_issue_artifacts(identifier)

  defp cleanup_terminal_issue_workspace(_issue), do: :ok

  defp cleanup_issue_workspace_for_issue(%Issue{identifier: identifier})
       when is_binary(identifier),
       do: cleanup_issue_workspace(identifier)

  defp cleanup_issue_workspace_for_issue(_issue), do: :ok
end
