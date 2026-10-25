defmodule Aiur.Orchestrator.IssueSync.TerminalVerification do
  @moduledoc """
  Retains disappearing issues until terminal membership is durably reconciled.
  """

  alias Aiur.CurrentRunMembership
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.MembershipLifecycle
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks

  @idle_terminal_verification_batch_size 25
  @doc false
  @spec record_disappearing_idle_terminals(State.t(), map(), map(), function(), function(), MapSet.t(), function(), function()) :: {State.t(), map()}
  def record_disappearing_idle_terminals(
        %State{} = state,
        previous_issues,
        current_issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      ) do
    disappearing_idle_issue_ids =
      previous_issues
      |> Map.keys()
      |> Enum.reject(fn arg1 -> idle_terminal_missing?(arg1, {current_issues, state}) end)
      |> Enum.sort()

    state = %{state | terminal_verification_attempts: Map.take(state.terminal_verification_attempts, disappearing_idle_issue_ids)}

    async? = TrackerTasks.owner?(state) and disappearing_idle_issue_ids != []

    cond do
      async? and TrackerTasks.running?(state, :idle_terminal_verification) ->
        {state, Map.merge(current_issues, Map.take(previous_issues, disappearing_idle_issue_ids))}

      async? ->
        verification_ids = Enum.take(disappearing_idle_issue_ids, @idle_terminal_verification_batch_size)
        state = %{state | terminal_verification_attempts: Enum.reduce(verification_ids, state.terminal_verification_attempts, &Map.put_new(&2, &1, 0))}
        inputs = Map.new(verification_ids, &{&1, {Reconciler.issue_input(state, &1), state.terminal_verification_attempts[&1]}})

        state =
          TrackerTasks.run(
            state,
            :idle_terminal_verification,
            fn ->
              fetch_idle_terminal_states({fetch_issue_states_fun, verification_ids})
            end,
            fn arg1, arg2 ->
              apply_idle_terminal_states(
                arg1,
                arg2,
                {inputs, mark_reconciled_fun, observe_membership_fun, set_terminal_verification_pending_fun, terminal_states, verification_ids}
              )
            end
          )

        {state, Map.merge(current_issues, Map.take(previous_issues, disappearing_idle_issue_ids))}

      true ->
        record_disappearing_idle_terminals_sync(
          state,
          current_issues,
          disappearing_idle_issue_ids,
          fetch_issue_states_fun,
          observe_membership_fun,
          terminal_states,
          mark_reconciled_fun,
          set_terminal_verification_pending_fun
        )
    end
  end

  defp filter_terminal_result({:ok, issues}, ids) when is_list(issues), do: {:ok, Enum.filter(issues, &(&1.id in ids))}
  defp filter_terminal_result(result, _ids), do: result

  defp record_disappearing_idle_terminals_sync(
         state,
         current_issues,
         disappearing_idle_issue_ids,
         fetch_issue_states_fun,
         observe_membership_fun,
         terminal_states,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    pending_issue_ids =
      record_refreshed_terminal_membership(
        disappearing_idle_issue_ids,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        set_terminal_verification_pending_fun
      )

    {state, pending_issue_ids} = MembershipLifecycle.bound_terminal_verification(state, Enum.take(disappearing_idle_issue_ids, @idle_terminal_verification_batch_size), pending_issue_ids)

    retain_pending_terminal_verification(pending_issue_ids, mark_reconciled_fun)

    {state, Map.merge(current_issues, Map.take(state.last_polled_issues, pending_issue_ids))}
  end

  defp record_refreshed_terminal_membership(
         [],
         _fetch_issue_states_fun,
         _observe_membership_fun,
         _terminal_states,
         _set_terminal_verification_pending_fun
       ),
       do: []

  defp record_refreshed_terminal_membership(
         issue_ids,
         fetch_issue_states_fun,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    {verification_issue_ids, deferred_issue_ids} =
      Enum.split(issue_ids, @idle_terminal_verification_batch_size)

    disappeared_issue_ids = MapSet.new(verification_issue_ids)

    case fetch_issue_states_fun.(verification_issue_ids) do
      {:ok, refreshed_issues} when is_list(refreshed_issues) ->
        returned_issue_ids =
          refreshed_issues
          |> Enum.flat_map(fn
            %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
            _issue -> []
          end)
          |> MapSet.new()

        failed_issue_ids =
          Enum.reduce(
            refreshed_issues,
            MapSet.difference(disappeared_issue_ids, returned_issue_ids),
            fn issue, failed_issue_ids ->
              issue
              |> record_refreshed_terminal_member(
                disappeared_issue_ids,
                observe_membership_fun,
                terminal_states,
                set_terminal_verification_pending_fun
              )
              |> retain_refreshed_terminal_verification(
                failed_issue_ids,
                issue,
                set_terminal_verification_pending_fun
              )
            end
          )

        MapSet.to_list(failed_issue_ids) ++ deferred_issue_ids

      _result ->
        verification_issue_ids ++ deferred_issue_ids
    end
  end

  defp record_refreshed_terminal_member(
         %Issue{id: _issue_id} = issue,
         disappeared_issue_ids,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    if terminal_disappearing_issue?(issue, disappeared_issue_ids, terminal_states) do
      record_and_clear_refreshed_terminal(
        issue,
        observe_membership_fun,
        set_terminal_verification_pending_fun
      )
    else
      :not_terminal
    end
  end

  defp record_refreshed_terminal_member(
         _issue,
         _disappeared_issue_ids,
         _observe_membership_fun,
         _terminal_states,
         _set_terminal_verification_pending_fun
       ),
       do: :not_terminal

  defp retain_refreshed_terminal_verification(
         result,
         failed_issue_ids,
         issue,
         _set_terminal_verification_pending_fun
       )
       when result in [:ok, :not_terminal] do
    MapSet.delete(failed_issue_ids, issue.id)
  end

  defp retain_refreshed_terminal_verification(
         {:error, _reason},
         failed_issue_ids,
         issue,
         set_terminal_verification_pending_fun
       ) do
    _ =
      CurrentRunMembership.set_terminal_verification_pending(
        set_terminal_verification_pending_fun,
        issue.tracker_identity,
        true
      )

    MapSet.put(failed_issue_ids, issue.id)
  end

  defp terminal_disappearing_issue?(issue, disappeared_issue_ids, terminal_states) do
    MapSet.member?(disappeared_issue_ids, issue.id) and
      DispatchPolicy.terminal_issue_state?(issue.state, terminal_states)
  end

  defp record_and_clear_refreshed_terminal(
         issue,
         observe_membership_fun,
         set_terminal_verification_pending_fun
       ) do
    case MembershipLifecycle.record(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           observe_membership_fun
         ) do
      :ok ->
        clear_refreshed_terminal_verification(
          issue,
          set_terminal_verification_pending_fun
        )

      error ->
        error
    end
  end

  defp clear_refreshed_terminal_verification(issue, set_terminal_verification_pending_fun) do
    case CurrentRunMembership.set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      result when result in [:ok, :skipped] -> :ok
      :error -> {:error, :terminal_verification_marker_failed}
    end
  end

  defp retain_pending_terminal_verification([], _mark_reconciled_fun), do: :ok

  defp retain_pending_terminal_verification(pending_issue_ids, mark_reconciled_fun) when is_list(pending_issue_ids) do
    safely_mark_reconciled(mark_reconciled_fun, :unavailable)
  end

  defp safely_mark_reconciled(mark_reconciled_fun, status) do
    _ = mark_reconciled_fun.(status)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp idle_terminal_missing?(issue_id, {current_issues, state}) do
    Map.has_key?(current_issues, issue_id) or
      Map.has_key?(state.running, issue_id) or
      Map.has_key?(state.retry_attempts, issue_id)
  end

  defp fetch_idle_terminal_states({fetch_issue_states_fun, verification_ids}) do
    fetch_issue_states_fun.(verification_ids)
  end

  defp apply_idle_terminal_states(
         current,
         result,
         {inputs, mark_reconciled_fun, observe_membership_fun, set_terminal_verification_pending_fun, terminal_states, verification_ids}
       ) do
    eligible_ids =
      Enum.filter(verification_ids, &({Reconciler.issue_input(current, &1), current.terminal_verification_attempts[&1]} == inputs[&1]))

    pending_ids =
      record_refreshed_terminal_membership(
        eligible_ids,
        fn arg1 ->
          apply_idle_terminal_entry(
            arg1,
            {eligible_ids, result}
          )
        end,
        observe_membership_fun,
        terminal_states,
        set_terminal_verification_pending_fun
      )

    {current, pending_ids} = MembershipLifecycle.bound_terminal_verification(current, eligible_ids, pending_ids)

    retain_pending_terminal_verification(pending_ids, mark_reconciled_fun)

    resolved_ids = eligible_ids -- pending_ids

    %{
      current
      | last_polled_issues: Map.drop(current.last_polled_issues, resolved_ids),
        released_claims: Map.drop(current.released_claims, resolved_ids)
    }
  end

  defp apply_idle_terminal_entry(
         _ids,
         {eligible_ids, result}
       ) do
    filter_terminal_result(result, eligible_ids)
  end
end
