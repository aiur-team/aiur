defmodule Aiur.Orchestrator.GithubBudgetPause do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{ControlLifecycle, State}
  alias Aiur.Protocol.MapAccess

  @budget_resources ["core", "graphql"]
  # A shared hold's advertised reset must be bounded to the broker's own
  # window (24 h in the future). A reset that far in the *past* is not a live
  # hold — it is a stale or forged value — so it must not be accepted: a past
  # reset would clamp to a zero delay and produce an immediate resume ->
  # immediate re-pause loop. A small past slack keeps a slightly-elapsed reset
  # (recovery arriving just after the advertised moment) on the immediate
  # recovery path.
  @max_budget_hold_ms 86_400_000
  @max_elapsed_hold_ms 300_000
  # Wake backoff is keyed on consecutive budget-pause generations (#2227
  # rework): generation 1 wakes at the advertised reset, generation 2 waits
  # one base step past it, and so on up to the cap. Without it, a hold that
  # keeps getting re-armed (another agent's refusal extends it) would resume ->
  # re-pause -> resume forever, one full pause cycle per reset instant.
  @base_backoff_ms 30_000
  @max_backoff_ms 600_000
  # At or past this many consecutive budget pauses the agent escalates to an
  # operator attention instead of looping silently.
  @escalation_generation 5
  # Per-agent jitter spreads the fleet wake: every budget-paused agent shares
  # the same reset instant, and without jitter every timer fires in the same
  # millisecond — the exact burst that re-trips a secondary limit. Read at
  # runtime so tests can shrink it.
  @default_max_jitter_ms 5_000

  @spec parse(map(), map(), integer()) :: map() | nil
  def parse(payload, entry, now_ms \\ System.system_time(:millisecond)) do
    reason = MapAccess.get(payload, :reason)
    resource = MapAccess.get(payload, :resource)
    reset_at_ms = MapAccess.get(payload, :reset_at_ms)

    if reason == "github_budget_hold" and resource in @budget_resources and is_integer(reset_at_ms) and
         reset_at_ms <= now_ms + @max_budget_hold_ms and reset_at_ms >= now_ms - @max_elapsed_hold_ms do
      %{resource: resource, reset_at_ms: reset_at_ms, generation: next_generation(entry, now_ms)}
    end
  end

  @doc false
  @spec next_generation(map(), integer()) :: pos_integer()
  def next_generation(entry, now_ms) when is_map(entry) and is_integer(now_ms) do
    case Map.get(entry, :github_budget_last_pause_ms) do
      last_pause_ms when is_integer(last_pause_ms) ->
        if now_ms - last_pause_ms <= consecutive_window_ms() do
          Map.get(entry, :github_budget_pause_generation, 0) + 1
        else
          1
        end

      _stale_or_absent ->
        1
    end
  end

  # A re-pause counts as "consecutive" only while the previous budget pause is
  # still inside the wake window. Once the agent has stayed working longer than
  # the maximum backoff, the next budget hold is a fresh episode (generation 1)
  # rather than inheriting an ever-growing counter.
  defp consecutive_window_ms, do: @max_backoff_ms

  @spec clear_context(map()) :: map()
  def clear_context(entry) do
    cancel_timer(entry)

    entry
    |> Map.delete(:github_budget_pause)
    |> Map.delete(:github_budget_pause_timer)
    |> Map.delete(:github_budget_last_pause_ms)
    |> Map.delete(:github_budget_pause_generation)
    |> Map.delete(:pending_auto_resume)
  end

  @doc false
  @spec cancel_timer(map()) :: :ok
  def cancel_timer(entry) when is_map(entry) do
    case Map.get(entry, :github_budget_pause_timer) do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _none -> :ok
    end

    :ok
  end

  @spec schedule_expiry(String.t(), pos_integer(), integer(), integer()) :: reference()
  def schedule_expiry(identifier, generation, reset_at_ms, now_ms \\ System.system_time(:millisecond))
      when is_binary(identifier) and is_integer(generation) and generation > 0 do
    delay_ms = max(reset_at_ms - now_ms, 0) + backoff_ms(generation) + jitter_ms(identifier)
    Process.send_after(self(), {:github_budget_pause_expired, identifier, generation}, delay_ms)
  end

  @doc false
  @spec backoff_ms(pos_integer()) :: non_neg_integer()
  def backoff_ms(generation) when is_integer(generation) and generation > 0 do
    if generation <= 1 do
      0
    else
      min(@max_backoff_ms, @base_backoff_ms * Integer.pow(2, generation - 2))
    end
  end

  @doc false
  @spec jitter_ms(String.t()) :: non_neg_integer()
  def jitter_ms(identifier) when is_binary(identifier) do
    max_jitter = max_jitter_ms()

    if max_jitter > 0 do
      # Deterministic per-agent spread: different identifiers wake at different
      # offsets so a fleet sharing one reset instant does not re-enter admission
      # together.
      :erlang.phash2(identifier, max_jitter)
    else
      0
    end
  end

  @doc false
  @spec max_jitter_ms() :: non_neg_integer()
  def max_jitter_ms do
    Application.get_env(:aiur, :github_budget_wake_jitter_ms, @default_max_jitter_ms)
  end

  @doc false
  @spec escalating_generation?(pos_integer()) :: boolean()
  def escalating_generation?(generation), do: is_integer(generation) and generation == @escalation_generation

  @doc false
  @spec emit_escalation_if_needed(map(), pos_integer()) :: :ok
  def emit_escalation_if_needed(entry, generation) when is_map(entry) and is_integer(generation) do
    if escalating_generation?(generation) do
      Alerts.emit_system("ticket.#{Map.get(entry, :identifier)}.github-budget.escalation",
        issue: Map.get(entry, :identifier),
        workspace: Map.get(entry, :workspace_path),
        worker_host: Map.get(entry, :worker_host),
        message: "GitHub budget hold persisting",
        reason:
          "Agent #{Map.get(entry, :identifier)} re-paused on the same GitHub budget hold #{generation} " <>
            "consecutive times; automatic retries continue with exponential backoff, but the hold is persisting.",
        needs_attention: true,
        severity: "warning"
      )
    end

    :ok
  end

  @spec recover_observed(State.t(), integer()) :: State.t()
  def recover_observed(%State{} = state, now_ms \\ System.system_time(:millisecond)) do
    Enum.each(state.running, fn {_issue_id, entry} ->
      case Map.get(entry, :github_budget_pause) do
        %{reset_at_ms: reset_at_ms, generation: generation}
        when is_integer(reset_at_ms) and is_integer(generation) and generation > 0 and reset_at_ms <= now_ms ->
          # Fleet-wide recovery must not resume every eligible agent in one
          # synchronous pass: they share the same reset instant, so that is the
          # exact stampede that re-trips a secondary limit. Wake each entry on
          # its own per-agent jittered timer; the expiry path stamps durable
          # readiness and resumes (or defers to the pending_auto_resume drain).
          wake(Map.get(entry, :identifier), generation, reset_at_ms, now_ms)

        _ ->
          :ok
      end
    end)

    state
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

  defp wake(identifier, generation, reset_at_ms, now_ms) when is_binary(identifier) do
    delay_ms = max(reset_at_ms - now_ms, 0) + jitter_ms(identifier)
    Process.send_after(self(), {:github_budget_pause_expired, identifier, generation}, delay_ms)
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
