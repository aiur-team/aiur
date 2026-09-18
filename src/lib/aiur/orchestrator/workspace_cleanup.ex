defmodule Aiur.Orchestrator.WorkspaceCleanup do
  @moduledoc """
  Owns orchestrator WorkspaceCleanup behavior.

  The functions run inside the orchestrator GenServer process, except the
  save and delete of a closed ticket's workspace. That work can take as long
  as the uncommitted-work save it includes (#2743), so
  `start_terminal_workspace_cleanups/1` runs it in one task under
  `Aiur.TaskSupervisor`, one workspace after the other, and sends
  `{:workspace_cleanup_finished, workspace_identifier, result}` to the caller
  after each. The startup todo cleanup stays in the Orchestrator because it
  must finish before the first dispatch; it runs one `git status` with a short
  time limit per workspace and keeps a dirty workspace for the dispatch-time
  recreate, which saves the work in the runner process.

  Because the terminal cleanup runs in a task, the ticket can be reopened and
  dispatched while its save runs, and the new runner claims the workspace
  lease. Immediately before the delete, the cleanup reads the lease again. A
  lease whose generation was not there when the cleanup was requested belongs
  to a new run: the workspace and the save are kept, the restore notices do
  not expire, and the result is `{:skipped, :live_lease}`. The lease of the
  closing run, which can still be reaping, does not stop the delete, as before
  #2743.

  An exception, exit or throw in one entry is logged and reported, and the
  remaining entries still run. A workspace whose cleanup crashed before the
  delete stays in place until the terminal sweep at the next daemon start.
  """

  require Logger

  alias Aiur.{Config, Issue, SessionHandle, Tracker, Workspace}
  alias Aiur.Orchestrator.{DispatchPolicy, RetryEngine, State, TrackerHealth}
  alias Aiur.Workspace.{Layout, Ownership, WipPreservation}

  @type terminal_cleanup :: {ticket :: String.t(), workspace_identifier :: String.t(), worker_host :: String.t() | nil}

  @spec cleanup_issue_workspace(binary() | term(), binary() | nil) :: :ok
  def cleanup_issue_workspace(identifier, worker_host \\ nil)

  def cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host, ticket: identifier, keep_dirty?: true)
  end

  @doc false
  @spec cleanup_terminal_issue_artifacts(binary() | term(), binary() | nil) :: :ok
  def cleanup_terminal_issue_artifacts(identifier, worker_host \\ nil)

  def cleanup_terminal_issue_artifacts(identifier, worker_host) when is_binary(identifier) do
    start_terminal_workspace_cleanups([{identifier, identifier, worker_host}])
    clear_session_handle(identifier)
  end

  @doc """
  Saves and deletes the workspaces of closed tickets off the calling process.
  Each entry names the ticket (for alerts), the workspace identifier (the
  workspace leaf) and the worker host. Closing a ticket also expires the
  restore notices of its workspace.
  """
  @spec start_terminal_workspace_cleanups([terminal_cleanup()]) :: :ok
  def start_terminal_workspace_cleanups([]), do: :ok

  def start_terminal_workspace_cleanups(cleanups) when is_list(cleanups) do
    notify = self()
    # The lease generation of each ticket at request time. The closing run's
    # lease can still be reaping; any other lease found before the delete
    # belongs to a new run.
    cleanups = Enum.map(cleanups, fn {ticket, _workspace_identifier, _worker_host} = entry -> {entry, lease_generation(ticket)} end)
    run = fn -> Enum.each(cleanups, &run_terminal_workspace_cleanup_entry(&1, notify)) end

    case Process.whereis(Aiur.TaskSupervisor) && Task.Supervisor.start_child(Aiur.TaskSupervisor, run) do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.warning("Running terminal workspace cleanup inline; task supervisor unavailable: #{inspect(other)}")
        run.()
    end
  end

  defp run_terminal_workspace_cleanup_entry({{ticket, workspace_identifier, _worker_host}, _known_generation} = entry, notify) do
    # One cleanup of a workspace at a time, even when a teardown and a sweep
    # ask for the same one.
    result =
      contain(ticket, workspace_identifier, fn ->
        :global.trans({{__MODULE__, workspace_identifier}, self()}, fn -> clean_up_terminal_workspace(entry) end)
      end)

    send(notify, {:workspace_cleanup_finished, workspace_identifier, result})
  end

  defp clean_up_terminal_workspace({{ticket, workspace_identifier, worker_host}, known_generation}) do
    guard = fn -> new_run_lease_guard(ticket, known_generation) end
    opts = [ticket: ticket, terminal?: true, destroy_guard: guard]

    case Workspace.remove_issue_workspaces(workspace_identifier, worker_host, opts) do
      {:skipped, :live_lease} = skipped ->
        Logger.warning("Kept closed ticket's workspace: a new run claimed it during the cleanup; the save and its notices are kept ticket=#{ticket} workspace=#{workspace_identifier}")

        skipped

      _removed ->
        WipPreservation.expire_notices(Layout.safe_identifier(workspace_identifier))
    end
  end

  @doc false
  # Runs one cleanup entry so that an exception, an exit or a throw becomes
  # `{:error, message}` and the task goes on to the next entry.
  @spec contain(term(), term(), (-> result)) :: result | {:error, String.t()} when result: term()
  def contain(ticket, workspace_identifier, fun) do
    fun.()
  rescue
    error -> crashed(ticket, workspace_identifier, Exception.message(error))
  catch
    kind, reason when kind in [:exit, :throw] -> crashed(ticket, workspace_identifier, "#{kind}: #{inspect(reason)}")
  end

  defp crashed(ticket, workspace_identifier, message) do
    Logger.error("Terminal workspace cleanup failed ticket=#{ticket} workspace=#{workspace_identifier} error=#{message}")
    {:error, message}
  end

  defp lease_generation(ticket) when is_binary(ticket) do
    case Ownership.current(ticket) do
      {:ok, %{generation: generation}} -> generation
      :none -> nil
    end
  end

  defp lease_generation(_ticket), do: nil

  defp new_run_lease_guard(ticket, known_generation) do
    case Ownership.current(ticket) do
      :none -> :ok
      {:ok, %{generation: ^known_generation}} -> :ok
      {:ok, _new_lease} -> {:skipped, :live_lease}
    end
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
        issues
        |> Enum.flat_map(&terminal_issue_cleanup/1)
        |> start_terminal_workspace_cleanups()

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

  # The startup sweep of closed tickets runs in one task, one workspace after
  # the other, so a long list neither blocks the Orchestrator nor starts a git
  # process per ticket at once.
  defp terminal_issue_cleanup(%Issue{identifier: identifier}) when is_binary(identifier) do
    clear_session_handle(identifier)
    [{identifier, identifier, nil}]
  end

  defp terminal_issue_cleanup(_issue), do: []

  # A todo ticket can still hold a workspace lease at startup, for example a
  # runner the Orchestrator just stopped whose guardian is still reaping it.
  # The lease owns the checkout until it is released, so leave it in place.
  defp cleanup_issue_workspace_for_issue(%Issue{identifier: identifier})
       when is_binary(identifier) do
    case Ownership.current(identifier) do
      :none -> cleanup_issue_workspace(identifier)
      {:ok, _lease} -> :ok
    end
  end

  defp cleanup_issue_workspace_for_issue(_issue), do: :ok
end
