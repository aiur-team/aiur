defmodule Aiur.Orchestrator.OptimisticGuardEffects do
  @moduledoc "Reconciles optimistic failure policy and journals resumable park effects."
  require Logger
  alias Aiur.{BuildQueue, CodeHost, Config}
  alias Aiur.Orchestrator.{OptimisticGuard, OptimisticGuardObservations, OptimisticLedger, PauseResume, State, TicketTransition, TrackerTasks}

  @spec reconcile(State.t(), keyword()) :: State.t()
  def reconcile(state, opts \\ []) do
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)

    with {:ok, rows} <- ledger.guard_records(), false <- rows == [] do
      records = rows
      opts = options(opts) |> Keyword.put(:issues, Map.new(Map.values(state.last_polled_issues), &{to_string(&1.identifier), &1}))

      read_observations(state, records, opts)
    else
      _ -> state
    end
  end

  defp read_observations(state, records, opts) do
    if TrackerTasks.running?(state, :optimistic_guard) do
      state
    else
      TrackerTasks.run(state, :optimistic_guard, fn -> Keyword.get(opts, :observe, &OptimisticGuardObservations.read/3).(records, now(opts), opts) end, fn current, observations ->
        apply_observations(current, records, observations, opts)
      end)
    end
  end

  defp options(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Config.settings!/0)

    Keyword.merge(
      [
        grace_ms: settings.build_queue.optimistic_failure_grace_seconds * 1000,
        churn_threshold: settings.build_queue.optimistic_churn_attention_threshold,
        observation_max_age_ms: (settings.build_queue.observation_max_age_seconds || 2 * settings.polling.interval_seconds) * 1000,
        label_prefix: settings.tracker.github.label_prefix
      ],
      opts
    )
  end

  defp apply_observations(state, records, observations, opts) when is_map(observations) do
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)

    for row <- records, row["status"] != "closed", blocker <- row["blockers"], observation = observations[blocker["id"]], observation[:confirmed?] == true do
      persisted = observation |> Map.drop([:edges]) |> Map.new(fn {key, value} -> {to_string(key), value} end)
      ledger.update_blocker(row["ticket"], blocker["id"], %{guard_observation: persisted})
    end

    state = release_records(state, records, observations, opts)
    running = MapSet.new(Map.values(state.running), &to_string(&1.issue.identifier))

    case ledger.guard_records() do
      {:ok, records} ->
        actions = OptimisticGuard.decide(records, observations, now(opts), Keyword.put(opts, :running_dependents, running))
        actions = actions ++ for(row <- records, row["status"] == "closed", do: {:resolve, :optimistic_blocker_failed, row["ticket"]})
        Enum.reduce(actions, state, &execute(&2, &1, opts))

      error ->
        report(state, "ledger", error)
    end
  end

  defp apply_observations(state, records, result, _opts), do: report(state, Enum.map_join(records, ",", & &1["ticket"]), result)

  @spec execute(State.t(), tuple(), keyword()) :: State.t()
  def execute(state, {:update_blocker, dep, blocker, facts}, opts) do
    Keyword.get(opts, :ledger, OptimisticLedger).update_blocker(dep, blocker, facts)
    state
  end

  def execute(state, {:park, dep, blocker, cause}, opts) do
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)

    with :ok <- ledger.begin_park(dep, blocker, cause_atom(cause), now(opts)),
         {:ok, %{"status" => "parked"} = row} <- ledger.get(dep) do
      facts = Enum.find(row["blockers"], &(&1["id"] == blocker))
      entry = State.find_running_by_identifier(state.running, dep)
      action = facts["park_action"] || if(is_map(entry) and not State.deactivated_running_entry?(entry) and not State.completed_provenance?(entry), do: "paused_parked", else: "parked")

      case ledger.update_blocker(dep, blocker, %{park_action: action}) do
        :ok ->
          pause_and_finish(state, dep, blocker, cause, facts, opts)

        error ->
          report(state, dep, error)
      end
    else
      error -> report(state, dep, error)
    end
  end

  def execute(state, {:attention, _cause, dep, %{action: action} = payload}, opts) when action == :none,
    do: TrackerTasks.run(state, {:optimistic_attention, dep}, fn -> attention(:open, dep, payload, opts) end, fn current, result -> report(current, dep, result) end)

  def execute(state, {:attention, _, _, _}, _opts), do: state

  def execute(state, {:resolve, _cause, dep}, opts),
    do: TrackerTasks.run(state, {:optimistic_attention, dep}, fn -> attention(:resolve, dep, %{}, opts) end, fn current, result -> report(current, dep, result) end)

  defp pause_and_finish(state, dep, blocker, cause, facts, opts) do
    {state, paused?} = pause(state, dep, facts, opts)
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)
    if paused?, do: ledger.update_blocker(dep, blocker, %{pause_complete: true})
    TrackerTasks.run(state, {:optimistic_park, dep}, fn -> finish_park(dep, blocker, cause, paused?, opts) end, fn current, result -> report(current, dep, result) end)
  end

  defp pause(state, dep, facts, opts) do
    entry = State.find_running_by_identifier(state.running, dep)

    cond do
      facts["pause_complete"] == true ->
        {state, true}

      state.globally_paused ->
        {state, false}

      inactive?(entry) ->
        {state, true}

      State.paused_running_entry?(entry) ->
        {state, true}

      PauseResume.current_pending_pause_reason(state, entry) == :optimistic_blocker_failed ->
        {state, false}

      true ->
        pause = Keyword.get(opts, :pause, fn current, running -> PauseResume.request_pause(current, running, running.issue, :optimistic_blocker_failed) end)
        {_reply, state} = pause.(state, entry)
        current = State.find_running_by_identifier(state.running, dep)
        {state, is_map(current) and State.paused_running_entry?(current)}
    end
  end

  defp inactive?(nil), do: true
  defp inactive?(entry), do: State.deactivated_running_entry?(entry) or State.completed_provenance?(entry)

  defp finish_park(dep, blocker, cause, paused?, opts) do
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)
    label = Keyword.get(opts, :label, &TicketTransition.write_marker(&1, :add, &2, writer: :optimistic_guard))
    draft = Keyword.get(opts, :draft, &CodeHost.park_pull_request/1)
    comment = Keyword.get(opts, :comment, &CodeHost.comment_optimistic_park/3)

    with {:ok, action} <- park_action(dep, blocker, ledger),
         :ok <- step(dep, blocker, "label_complete", fn -> label.(dep, Keyword.fetch!(opts, :label_prefix) <> ":parked") end, ledger),
         :ok <- step(dep, blocker, "draft_complete", fn -> draft.(dep) end, ledger),
         :ok <- step(dep, blocker, "comment_complete", fn -> comment.(dep, blocker, cause) end, ledger),
         :ok <- attention(:open, dep, %{blocker: blocker, cause: cause_atom(cause), action: action, severity: "warning"}, opts) do
      if paused?, do: ledger.update_blocker(dep, blocker, %{park_complete: true}), else: :ok
    end
  end

  defp step(dep, blocker, key, effect, ledger) do
    with {:ok, row} <- ledger.get(dep),
         facts when is_map(facts) <- Enum.find(row["blockers"], &(&1["id"] == blocker)) do
      perform_step(facts[key], dep, blocker, key, effect, ledger)
    end
  end

  defp perform_step(true, _dep, _blocker, _key, _effect, _ledger), do: :ok

  defp perform_step(_, dep, blocker, key, effect, ledger) do
    with :ok <- effect.(), do: ledger.update_blocker(dep, blocker, %{key => true})
  end

  defp attention(action, dep, payload, opts) do
    callback = Keyword.get(opts, :attention, &BuildQueue.optimistic_attention/3)
    payload = Map.update(payload, :cause, :optimistic_blocker_failed, &cause_atom/1)

    result =
      case callback.(action, dep, payload) do
        {:error, :disabled} -> transient_attention(action, dep, payload, opts)
        result -> result
      end

    if result == :ok, do: Keyword.get(opts, :ledger, OptimisticLedger).attention_status(dep, action == :open)
    result
  end

  defp transient_attention(action, dep, payload, opts) do
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)

    with {:ok, row} when is_map(row) <- ledger.get(dep) do
      blocker = payload[:blocker] || hd(row["blockers"])["id"]
      facts = Enum.find(row["blockers"], &(&1["id"] == blocker)) || hd(row["blockers"])

      emit_transient(action, dep, payload, facts, row, ledger)
    end
  end

  defp emit_transient(action, dep, payload, facts, row, ledger) do
    cond do
      action == :open and facts[attention_key(payload)] != true ->
        with :ok <- BuildQueue.transient_optimistic_attention(dep, payload, false),
             do: ledger.update_blocker(dep, facts["id"], %{attention_key(payload) => true})

      action == :resolve and row["guard_attention_open"] == true ->
        BuildQueue.transient_optimistic_attention(dep, %{}, true)

      true ->
        :ok
    end
  end

  defp attention_key(%{action: :none}), do: "info_attention_emitted"
  defp attention_key(_), do: "attention_emitted"

  defp park_action(dep, blocker, ledger) do
    with {:ok, row} when is_map(row) <- ledger.get(dep),
         facts when is_map(facts) <- Enum.find(row["blockers"], &(&1["id"] == blocker)) do
      {:ok, if(facts["park_action"] == "paused_parked", do: :paused_parked, else: :parked)}
    else
      error -> {:error, {:park_facts_unavailable, error}}
    end
  end

  defp release_records(state, records, observations, opts) do
    prefix = Keyword.fetch!(opts, :label_prefix)

    eligible =
      for row <- records,
          row["status"] == "parked",
          Enum.any?(row["blockers"], &(&1["park_complete"] == true)),
          issue = get_in(observations, [:dependents, row["ticket"]]),
          is_map(issue),
          recovery_ready?(row, observations, issue, prefix),
          do: row

    Enum.reduce(eligible, state, fn row, current ->
      issue = get_in(observations, [:dependents, row["ticket"]])
      entry = State.find_running_by_identifier(current.running, row["ticket"])
      live_paused? = optimistic_pause?(entry)
      target = if live_paused?, do: "in-progress", else: recovery_state(issue, prefix)

      update =
        Keyword.get(opts, :update_state_fun, fn identifier, state_name, expected -> TicketTransition.write_state(identifier, state_name, writer: :optimistic_guard, expected_state: expected) end)

      update_marker = Keyword.get(opts, :remove_marker_fun, fn identifier, marker -> TicketTransition.write_marker(identifier, :remove, marker, writer: :optimistic_guard) end)
      write_state? = (prefix <> ":parked") in issue.labels

      key = {:optimistic_recovery, row["ticket"]}

      context = %{
        row: row,
        entry: entry,
        live_paused?: live_paused?,
        issue: issue,
        prefix: prefix,
        target: target,
        opts: opts,
        update: update,
        update_marker: update_marker,
        write_state?: write_state?
      }

      schedule_recovery(current, key, context)
    end)
  end

  defp schedule_recovery(state, key, context) do
    if TrackerTasks.running?(state, key) do
      state
    else
      TrackerTasks.run(state, key, fn -> perform_recovery(context) end, fn next, result -> apply_recovery_result(next, result, context) end)
    end
  end

  defp perform_recovery(%{write_state?: write_state?, issue: issue, prefix: prefix, target: target, update: update, update_marker: update_marker, live_paused?: live_paused?, row: row, opts: opts}) do
    state_result = if write_state?, do: restore_dispatch_state(issue, target, prefix, update, update_marker), else: :ok

    case state_result do
      :ok when live_paused? -> :ok
      :ok -> Keyword.get(opts, :ledger, OptimisticLedger).resume_park(row["ticket"], now(opts))
      error -> error
    end
  end

  defp apply_recovery_result(state, :ok, %{live_paused?: true, entry: entry, issue: issue, prefix: prefix, target: target, row: row, opts: opts}) do
    case maybe_resume_optimistic_pause(state, entry, issue, prefix, target, opts) do
      {:ok, resumed} -> finish_live_recovery(resumed, row["ticket"], opts)
      {:error, error} -> report(state, row["ticket"], error)
    end
  end

  defp apply_recovery_result(state, :ok, %{row: row, opts: opts}),
    do: execute(state, {:resolve, :optimistic_blocker_failed, row["ticket"]}, opts)

  defp apply_recovery_result(state, error, %{row: row}), do: report(state, row["ticket"], error)

  defp recovery_state(issue, prefix) do
    if issue.state == "rework" or (prefix <> ":rework") in (issue.labels || []), do: "rework", else: "todo"
  end

  defp recovery_ready?(row, observations, issue, prefix) do
    marker = prefix <> ":parked"
    failed = Enum.any?(row["blockers"], fn blocker -> blocker["park_complete"] == true and blocker_recovered?(observations[blocker["id"]]) end)
    no_other_hold? = not independent_hold?(issue, marker, prefix)
    marker not in issue.labels or (failed and no_other_hold?)
  end

  defp blocker_recovered?(%{confirmed?: true, issue_open?: false, state_reason: reason}) when reason in [:completed, "completed"], do: true
  defp blocker_recovered?(%{confirmed?: true, pr_merged: true}), do: true
  defp blocker_recovered?(_), do: false

  defp restore_dispatch_state(issue, target, prefix, update, remove_marker) do
    expected = if is_binary(issue.state), do: issue.state, else: :none

    with :ok <- update.(issue.identifier, target, expected) do
      remove_marker.(issue.identifier, prefix <> ":parked")
    end
  end

  defp optimistic_pause?(%{paused_reason: :optimistic_blocker_failed} = entry), do: State.paused_running_entry?(entry)
  defp optimistic_pause?(_entry), do: false

  defp maybe_resume_optimistic_pause(state, entry, issue, prefix, target, opts) do
    refreshed_issue = %{issue | state: target, parked: false, state_labels: [target], labels: Enum.reject(issue.labels || [], &(&1 == prefix <> ":parked"))}
    refreshed_entry = %{entry | issue: refreshed_issue}

    resume = Keyword.get(opts, :resume_paused_fun)

    case if(is_function(resume, 2), do: resume.(state, refreshed_entry), else: PauseResume.resume_paused_issue(state, refreshed_entry, false)) do
      {{:ok, :resumed}, next} -> {:ok, next}
      {error, _next} -> {:error, error}
    end
  end

  defp finish_live_recovery(state, ticket, opts) do
    ledger = Keyword.get(opts, :ledger, OptimisticLedger)

    TrackerTasks.run(
      state,
      {:optimistic_recovery_finish, ticket},
      fn -> ledger.resume_park(ticket, now(opts)) end,
      fn
        current, :ok -> execute(current, {:resolve, :optimistic_blocker_failed, ticket}, opts)
        current, error -> report(current, ticket, error)
      end
    )
  end

  defp independent_hold?(issue, marker, prefix) do
    labels = issue.labels || []

    Enum.any?(labels, fn label ->
      label != marker and (label in [prefix <> ":paused", "needs-triage", "human:todo"] or String.starts_with?(label, "epic:"))
    end) or Map.get(issue, :executor_owner) not in [nil, ""] or Map.get(issue, :paused) == true
  end

  defp cause_atom(cause) when is_atom(cause), do: cause
  defp cause_atom(cause) when cause in ~w(agent_error pr_closed_unmerged not_planned duplicate edge_removed paused parked todo churn), do: String.to_existing_atom(cause)
  defp cause_atom("error"), do: :agent_error
  defp report(state, _dep, :ok), do: state

  defp report(state, dep, result) do
    Logger.warning("Optimistic guard effect pending ticket=#{dep}: #{inspect(result)}")
    state
  end

  defp now(opts), do: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end).()
end
