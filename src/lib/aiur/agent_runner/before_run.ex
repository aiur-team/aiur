defmodule Aiur.AgentRunner.BeforeRun do
  @moduledoc false

  require Logger
  alias Aiur.AgentRunner.{MessageHandler, WorkspaceGuard}
  alias Aiur.Workspace

  @spec run(Path.t(), Aiur.Issue.t(), keyword(), String.t() | nil, fun()) :: term()
  def run(workspace, issue, opts, worker_host, session) do
    case Workspace.run_before_run_hook(workspace, issue, worker_host) do
      :ok ->
        session.()

      {:error, {:workspace_hook_failed, "before_run", status, output} = reason} ->
        WorkspaceGuard.record_setup_end(issue, opts, :failed, status)
        {:before_run_failed, status, output, reason}

      {:error, {:workspace_hook_timeout, "before_run", timeout_ms} = reason} ->
        WorkspaceGuard.record_setup_end(issue, opts, :failed, reason)
        {:before_run_retry, reason, timeout_ms}

      # The dirty workspace could not be saved, so it was not recreated (#2743).
      # Hold the ticket on the existing before_run pause instead of letting a
      # retry chain run; the workspace keeps the agent's work. That pause has
      # no timeout: it lasts until an Executor resume (or an authorized
      # discard, then a resume).
      {:error, {:wip_preservation_failed, _workspace, detail} = reason} ->
        WorkspaceGuard.record_setup_end(issue, opts, :failed, reason)
        {:before_run_failed, :wip_preservation_failed, inspect(detail), reason}

      {:error, reason} ->
        WorkspaceGuard.record_setup_end(issue, opts, :failed, reason)
        {:error, reason}
    end
  end

  @spec pause_for_failure(Path.t(), Aiur.Issue.t(), pid() | nil, String.t() | nil, term(), term(), term()) :: :resume_after_before_run_pause
  def pause_for_failure(workspace, issue, codex_update_recipient, worker_host, status, output, reason) do
    Logger.warning("Pausing agent for #{Aiur.AgentRunner.issue_context(issue)} after before_run hook failed status=#{inspect(status)} output=#{inspect(trim_hook_output(output))}")

    Aiur.AgentRunner.write_pause_log(workspace, worker_host, before_run_pause_message(status))
    MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{kind: :before_run_failure})
    wait_for_before_run_resume(issue, codex_update_recipient, reason)
  end

  defp before_run_pause_message(:wip_preservation_failed),
    do: "wip_preservation_failed: uncommitted work could not be saved, so the dirty workspace was kept; agent held pending Executor resume."

  defp before_run_pause_message(:timeout),
    do: "before_run hook timed out; agent paused pending Executor resume."

  defp before_run_pause_message(_status), do: "before_run hook failed; agent paused pending Executor resume."

  defp wait_for_before_run_resume(issue, codex_update_recipient, reason) do
    receive do
      {:pause_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        Logger.info("Agent already paused before run for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{
          kind: :before_run_failure,
          request_id: request_id,
          generation: generation
        })

        wait_for_before_run_resume(issue, codex_update_recipient, reason)

      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused before run for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused, %{kind: :before_run_failure})
        wait_for_before_run_resume(issue, codex_update_recipient, reason)

      {:resume_agent, request_id, generation} when is_integer(request_id) and is_integer(generation) ->
        Logger.info("Resuming agent after before_run failure for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")

        MessageHandler.send_control_state(codex_update_recipient, issue, :working, %{
          request_id: request_id,
          generation: generation
        })

        :resume_after_before_run_pause

      {:resume_agent, request_id} when is_integer(request_id) ->
        Logger.info("Resuming agent after before_run failure for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :working)
        :resume_after_before_run_pause
    end
  end

  defp trim_hook_output(output) when is_binary(output), do: output |> String.trim() |> String.slice(0, 500)
  defp trim_hook_output(output), do: output
end
