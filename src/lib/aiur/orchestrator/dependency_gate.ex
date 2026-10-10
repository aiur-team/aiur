defmodule Aiur.Orchestrator.DependencyGate do
  @moduledoc "Dispatch prerequisite verdicts from hydrated states and recorded PR progress, without tracker I/O."

  alias Aiur.BuildQueue.Hints
  alias Aiur.{Issue, StartTrigger}
  alias Aiur.StartTrigger.{Evidence, ProgressStore}

  @spec verdicts(Issue.t(), MapSet.t()) :: [{map(), StartTrigger.verdict()}]
  def verdicts(%Issue{id: id, blocked_by: blockers}, terminal_states) when is_list(blockers) and blockers != [] do
    trigger = Hints.trigger_for(id)
    if trigger == :pr_approved, do: ProgressStore.watch(for(%{id: id} <- blockers, is_binary(id), do: id), trigger)
    now = System.system_time(:millisecond)
    max_age_ms = Hints.observation_max_age_ms()
    opts = [now_ms: now, max_age_ms: max_age_ms, not_planned: :satisfy]
    Enum.map(blockers, &{&1, StartTrigger.edge_verdict(trigger, evidence(&1, terminal_states, now, max_age_ms), opts)})
  end

  def verdicts(_issue, _terminal_states), do: []

  defp evidence(%{state: state} = blocker, terminal_states, now, max_age_ms) when is_binary(state) do
    state = state |> String.trim() |> String.downcase()
    terminal? = state != "error" and (state in ["closed", "not_planned"] or MapSet.member?(terminal_states, state))
    row = ProgressStore.lookup(Map.get(blocker, :id)) || %{}
    row_stage = fresh_stage(row, now, max_age_ms)
    # Final evidence never ages out; optimistic evidence is only as fresh as the label fetch.
    final? = terminal? or row_stage == :pr_merged

    %Evidence{
      issue_open?: not terminal?,
      state_reason: if(terminal?, do: "completed"),
      state_label: state,
      pr: if(Map.get(row, :closed_unmerged?, false), do: :closed_unmerged),
      pr_number: Map.get(row, :pr_number),
      stage_reached: row_stage,
      observed_at_ms: if(final?, do: now, else: Map.get(blocker, :observed_at_ms, now))
    }
  end

  defp evidence(_blocker, _terminal_states, now, _max_age_ms), do: %Evidence{observed_at_ms: now, unavailable_reason: :blocker_state_unreadable}

  defp fresh_stage(%{stage: stage, observed_at_ms: at}, now, max_age_ms) when is_integer(at) do
    if stage == :pr_merged or now - at <= max_age_ms, do: stage
  end

  defp fresh_stage(_row, _now, _max_age_ms), do: nil
end
