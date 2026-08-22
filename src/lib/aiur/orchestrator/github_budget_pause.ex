defmodule Aiur.Orchestrator.GithubBudgetPause do
  @moduledoc false

  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{ControlLifecycle, State}
  alias Aiur.Protocol.MapAccess

  @budget_resources ["core", "graphql"]
  @max_budget_hold_ms 86_400_000

  @spec parse(map(), map(), integer()) :: map() | nil
  def parse(payload, entry, now_ms \\ System.system_time(:millisecond)) do
    reason = MapAccess.get(payload, :reason)
    resource = MapAccess.get(payload, :resource)
    reset_at_ms = MapAccess.get(payload, :reset_at_ms)

    if reason == "github_budget_hold" and resource in @budget_resources and is_integer(reset_at_ms) and
         abs(reset_at_ms - now_ms) <= @max_budget_hold_ms do
      generation = Map.get(entry, :github_budget_pause_generation, 0) + 1
      %{resource: resource, reset_at_ms: reset_at_ms, generation: generation}
    end
  end

  @spec clear_context(map()) :: map()
  def clear_context(entry) do
    entry
    |> Map.delete(:github_budget_pause)
    |> Map.delete(:pending_auto_resume)
  end

  @spec schedule_expiry(String.t(), pos_integer(), integer(), integer()) :: reference()
  def schedule_expiry(identifier, generation, reset_at_ms, now_ms \\ System.system_time(:millisecond))
      when is_binary(identifier) do
    delay_ms = max(reset_at_ms - now_ms, 0)
    Process.send_after(self(), {:github_budget_pause_expired, identifier, generation}, delay_ms)
  end

  @spec recover_observed(State.t(), integer()) :: State.t()
  def recover_observed(%State{} = state, now_ms \\ System.system_time(:millisecond)) do
    Enum.reduce(state.running, state, fn {_issue_id, entry}, current ->
      case Map.get(entry, :github_budget_pause) do
        %{reset_at_ms: reset_at_ms} when is_integer(reset_at_ms) and reset_at_ms <= now_ms ->
          recover_entry(current, entry)

        _ ->
          current
      end
    end)
  end

  @spec recover_expired(State.t(), String.t(), pos_integer(), integer()) :: State.t()
  def recover_expired(%State{} = state, identifier, generation, now_ms \\ System.system_time(:millisecond)) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{github_budget_pause: %{generation: ^generation, reset_at_ms: reset_at_ms}} = entry
      when reset_at_ms <= now_ms ->
        recover_entry(state, entry)

      _ ->
        state
    end
  end

  @spec matching_hint_pause?(map(), map()) :: boolean()
  def matching_hint_pause?(entry, %{resume_kind: :github_budget_recovered, pause_generation: generation}) do
    matching_generation?(entry, generation) and Map.get(entry, :paused_reason) == :github_budget_hold
  end

  @spec matching_hint_context?(map(), map()) :: boolean()
  def matching_hint_context?(entry, %{resume_kind: :github_budget_recovered, pause_generation: generation}) do
    matching_generation?(entry, generation) and
      (Map.get(entry, :paused_reason) == :github_budget_hold or
         match?(%{reason: :github_budget_hold}, Map.get(entry, :pending_pause_reason)))
  end

  defp recover_entry(state, entry) do
    case Map.get(entry, :github_budget_pause) do
      %{generation: generation} ->
        if matching_generation?(entry, generation) and budget_pause_pending?(entry) do
          state
          |> stamp_auto_resume(entry, generation)
          |> maybe_resume(Map.get(entry, :identifier))
        else
          state
        end

      _ ->
        state
    end
  end

  defp matching_generation?(entry, generation) do
    get_in(entry, [:github_budget_pause, :generation]) == generation and
      Map.get(entry, :github_budget_pause_generation) == generation
  end

  defp budget_pause_pending?(entry) do
    Map.get(entry, :paused_reason) == :github_budget_hold or
      match?(%{reason: :github_budget_hold}, Map.get(entry, :pending_pause_reason))
  end

  defp stamp_auto_resume(state, entry, generation) do
    hint = %{resume_kind: :github_budget_recovered, pause_generation: generation, stamped_at: DateTime.utc_now()}
    update_running_entry(state, Map.get(entry, :identifier), &Map.put(&1, :pending_auto_resume, hint))
  end

  defp maybe_resume(state, identifier) do
    entry = State.find_running_by_identifier(state.running, identifier)

    if State.paused_running_entry?(entry) and not matching_resume_pending?(state, entry) do
      case Orchestrator.resume_paused_issue(state, entry, false) do
        {{:ok, :resumed}, next_state} -> next_state
        {{:error, _reason}, next_state} -> next_state
      end
    else
      state
    end
  end

  @spec matching_resume_pending?(State.t(), map()) :: boolean()
  def matching_resume_pending?(%State{} = state, entry) when is_map(entry) do
    issue_id = get_in(entry, [:issue, Access.key(:id)])
    control_generation = get_in(entry, [:control, :generation])

    case ControlLifecycle.current_pending(state.control_lifecycle, issue_id) do
      %{action: :resume, generation: ^control_generation} -> true
      _ -> false
    end
  end

  defp update_running_entry(state, identifier, fun) do
    case State.find_running_by_identifier(state.running, identifier) do
      %{issue: %{id: issue_id}} = entry -> %{state | running: Map.put(state.running, issue_id, fun.(entry))}
      _ -> state
    end
  end
end
