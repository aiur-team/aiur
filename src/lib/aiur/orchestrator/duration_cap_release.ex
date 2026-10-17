defmodule Aiur.Orchestrator.DurationCapRelease do
  @moduledoc """
  Hands a ticket whose worker parked at `agent.max_agent_duration_minutes` to
  a fresh worker (#4849): moves it with the startup reconciler's mapping (draft
  or no PR -> rework, ready PR -> human-review unless the PR needs rework), then
  frees the runner entry so it no longer holds a slot or blocks dispatch.
  """

  require Logger

  alias Aiur.Alerts
  alias Aiur.Orchestrator.{AgentTeardown, State, TrackerTasks}
  alias Aiur.Orchestrator.StartupClaimReconciler.Release

  @spec maybe_release(State.t(), map(), atom(), keyword()) :: State.t()
  def maybe_release(state, running_entry, status, opts \\ [])

  def maybe_release(%State{} = state, %{paused_reason: :max_agent_duration, issue: %{id: issue_id} = issue} = entry, :paused, opts) do
    opts = Keyword.merge(Application.get_env(:aiur, :duration_cap_release_opts, []), opts)
    release = fn -> Release.run(issue, release_opts(opts)) end
    TrackerTasks.run(state, {:duration_cap_release, issue_id}, release, &apply_release(&1, &2, entry, opts))
  end

  def maybe_release(state, _running_entry, _status, _opts), do: state

  defp release_opts(opts) do
    Keyword.merge(
      [
        no_pr_target: "rework",
        writer: :duration_cap_release,
        # This daemon owns the parked worker's lease; it is released right after the write.
        ownership_fun: fn _identifier -> :none end,
        release_body: &"Agent reached `agent.max_agent_duration_minutes`; released its runner and moved this ticket to #{&1} so the work continues."
      ],
      opts
    )
  end

  # The tracker write already landed, so a refresh that swapped `:issue` must not
  # keep the runner; only a different or resumed runner is left alone.
  @runner_fields [:pid, :ref, :session_id, :telemetry_attempt_id, :control]

  @doc false
  @spec apply_release(State.t(), term(), map(), keyword()) :: State.t()
  def apply_release(state, {:ok, target}, %{issue: %{id: issue_id}} = entry, opts) do
    if same_parked_runner?(Map.get(state.running, issue_id), entry) do
      Logger.warning("Released duration-capped agent to #{target} #{State.issue_context(entry.issue)}")
      resolve_pause_alert(entry, target, opts)
      AgentTeardown.terminate_running_issue(state, issue_id, false)
    else
      state
    end
  end

  # A failed or deferred write leaves the agent paused for the Executor, as before #4849.
  def apply_release(state, result, entry, _opts) do
    Logger.warning("Duration-capped agent stays paused; release did not complete: #{inspect(result)} #{State.issue_context(entry.issue)}")
    state
  end

  defp same_parked_runner?(%{paused_reason: :max_agent_duration} = current, entry),
    do: Map.take(current, @runner_fields) == Map.take(entry, @runner_fields)

  defp same_parked_runner?(_current, _entry), do: false

  defp resolve_pause_alert(entry, target, opts) do
    emit = Keyword.get(opts, :emit_alert_fun, &Alerts.emit_system/2)

    emit.("ticket.#{entry.identifier}.agent.attention.paused-max_agent_duration.resolved",
      issue: entry.identifier,
      workspace: Map.get(entry, :workspace_path),
      reason: "Duration-capped agent released; ticket moved to #{target}.",
      needs_attention: false,
      severity: "info"
    )
  end
end
