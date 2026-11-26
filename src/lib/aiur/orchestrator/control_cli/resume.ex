defmodule Aiur.Orchestrator.ControlCLI.Resume do
  @moduledoc false
  alias Aiur.ControlCLI.Reasons
  alias Aiur.Orchestrator.{ControlCLI, StatusReason}
  import Aiur.ControlCLI.Protocol
  import Aiur.Orchestrator.ControlCLI.Output
  @status_timeout_ms 5_000
  # `{:ok, :resumed}` from the orchestrator means a resume control request was
  # *enqueued* for the agent, not that the agent left the paused state (see
  # `Aiur.Orchestrator.PauseResume.send_resume_control_message/3`). Printing
  # "resumed #44" at that point is a confident wrong outcome: in #1634 three
  # agents stayed paused while the CLI reported no failure at all. So observe
  # the agent's own control status leaving `:paused` before claiming it, and
  # report an unconfirmed request as a failure rather than as success.
  #
  # Share one confirmation budget across resume --all to fit the launcher's 10s RPC timeout.
  @resume_confirm_timeout_ms 4_000
  @resume_confirm_poll_ms 100
  # Every resume queued by this invocation is confirmed by one shared polling
  # loop against one shared deadline: a single fleet read per tick settles all
  # of them at once. The wait is therefore bounded by the budget no matter how
  # many targets `--all` selected, and each read is capped by the time actually
  # left so a slow orchestrator cannot walk past the launcher's RPC timeout.
  @spec resolve_queued_resumes(list()) :: list()
  def resolve_queued_resumes(results) do
    queued =
      for {:queued_resume, status, request_id} <- results,
          do: %{canonical: canonical_identifier(status), request_id: request_id}

    if queued == [] do
      results
    else
      deadline = System.monotonic_time(:millisecond) + resume_confirm_timeout_ms()
      outcomes = await_resumes_applied(queued, deadline, %{}, nil)

      Enum.map(results, fn
        {:queued_resume, status, _request_id} ->
          report_resume(status, Map.fetch!(outcomes, canonical_identifier(status)))

        result ->
          result
      end)
    end
  end

  # `last_observed` is the most recent read that succeeded. Each read is capped
  # by the time left, so the final poll before the deadline gets only a sliver
  # of the budget; a read that misses that sliver says nothing about the control
  # state. When an earlier read did observe it, the window elapsed with that
  # state still unsettled, which is the verdict to report. "Status unreadable"
  # is reserved for a window in which no read succeeded at all (#2632, #2690).
  defp await_resumes_applied(pending, deadline, outcomes, last_observed) do
    case read_control_states(pending, remaining_ms(deadline)) do
      {:error, error} ->
        cond do
          remaining_ms(deadline) > @resume_confirm_poll_ms ->
            Process.sleep(@resume_confirm_poll_ms)
            await_resumes_applied(pending, deadline, outcomes, last_observed)

          is_map(last_observed) ->
            settle_timed_out(pending, last_observed, outcomes)

          true ->
            settle_all(pending, {:unknown, %{reason: {:status_unreadable, error}}}, outcomes)
        end

      {:ok, observed} ->
        {settled, waiting} = Enum.split_with(pending, &settled_resume_outcome?(Map.fetch!(observed, &1.canonical)))
        outcomes = Enum.into(settled, outcomes, &{&1.canonical, Map.fetch!(observed, &1.canonical)})

        cond do
          waiting == [] ->
            outcomes

          remaining_ms(deadline) <= @resume_confirm_poll_ms ->
            settle_timed_out(waiting, observed, outcomes)

          true ->
            Process.sleep(@resume_confirm_poll_ms)
            await_resumes_applied(waiting, deadline, outcomes, observed)
        end
    end
  end

  defp settle_timed_out(waiting, observed, outcomes) do
    Enum.into(waiting, outcomes, fn pending_resume ->
      outcome = observed |> Map.fetch!(pending_resume.canonical) |> timeout_resume_outcome()
      {pending_resume.canonical, outcome}
    end)
  end

  defp settle_all(pending, outcome, outcomes), do: Enum.into(pending, outcomes, &{&1.canonical, outcome})

  defp settled_resume_outcome?(:applied), do: true
  defp settled_resume_outcome?({outcome, _detail}) when outcome in [:declined, :dropped], do: true
  defp settled_resume_outcome?(_outcome), do: false

  defp timeout_resume_outcome({:pending, detail}),
    do: {:unknown, Map.put(detail, :reason, :confirmation_window_elapsed)}

  defp timeout_resume_outcome(outcome), do: outcome

  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Read every queued target from one fleet snapshot. The read never outlives
  # the confirmation budget, and never claims more than the status timeout.
  defp read_control_states(pending, remaining) do
    timeout_ms = remaining |> max(@resume_confirm_poll_ms) |> min(@status_timeout_ms)

    case ControlCLI.confirmation_status_snapshot(timeout_ms) do
      statuses when is_list(statuses) ->
        statuses_by_identifier = Map.new(statuses, &{canonical_identifier(&1), &1})

        {:ok,
         Map.new(pending, fn %{canonical: canonical, request_id: request_id} ->
           case Map.get(statuses_by_identifier, canonical) do
             nil -> {canonical, {:unknown, %{reason: :no_longer_tracked}}}
             status -> {canonical, resume_outcome(status, request_id)}
           end
         end)}

      error when error in [:timeout, :unavailable] ->
        {:error, error}
    end
  end

  defp resume_outcome(status, nil) do
    if Map.get(status, :state) == :paused,
      do: paused_resume_outcome(status, nil),
      else: :applied
  end

  defp resume_outcome(status, request_id) do
    latest = resume_control_outcome(status, request_id)

    if is_map(latest) and Map.get(latest, :request_id) == request_id and Map.get(latest, :status) == :applied,
      do: :applied,
      else: paused_resume_outcome(status, request_id, latest)
  end

  defp paused_resume_outcome(status, request_id, latest \\ nil) do
    latest = latest || resume_control_outcome(status, request_id)
    detail = held_resume_detail(status, latest)
    classify_paused_resume(latest, request_id, detail)
  end

  defp classify_paused_resume(latest, request_id, detail) do
    cond do
      not is_map(latest) -> unknown_outcome(detail, :missing_control_outcome)
      mismatched_request?(request_id, latest) -> unknown_outcome(detail, :mismatched_control_outcome)
      Map.get(latest, :action) != :resume -> unknown_outcome(detail, :mismatched_control_outcome)
      true -> resume_status_outcome(latest, detail)
    end
  end

  defp mismatched_request?(nil, _latest), do: false
  defp mismatched_request?(request_id, latest), do: Map.get(latest, :request_id) != request_id

  defp resume_status_outcome(latest, detail) do
    case Map.get(latest, :status) do
      :rejected -> {:declined, detail}
      :expired -> {:dropped, detail}
      status when status in [:requested, :accepted] -> {:pending, detail}
      _other -> unknown_outcome(detail, :inconsistent_control_outcome)
    end
  end

  defp unknown_outcome(detail, reason), do: {:unknown, Map.put(detail, :reason, reason)}

  defp resume_control_outcome(status, request_id) do
    control = Map.get(status, :control, %{})
    recent = Map.get(control, :recent_controls, [])
    correlated = Enum.find(recent, &(Map.get(&1, :request_id) == request_id))

    if is_map(correlated) do
      correlated
    else
      fallback_resume_control(control, request_id)
    end
  end

  defp fallback_resume_control(control, request_id) do
    latest_resume = Map.get(control, :latest_resume_control)
    latest = Map.get(control, :latest_control)

    Enum.find([latest_resume, latest], &matching_control?(&1, request_id)) ||
      latest_resume ||
      latest
  end

  defp matching_control?(control, request_id) when is_map(control) do
    is_nil(request_id) or Map.get(control, :request_id) == request_id
  end

  defp matching_control?(_control, _request_id), do: false

  defp held_resume_detail(status, latest) do
    condition = get_in(latest || %{}, [:rejection, :condition]) || %{}

    %{
      control_status: Map.get(condition, :control_status, Map.get(status, :work_state, :paused)),
      pause_reason: Map.get(condition, :pause_reason, Map.get(status, :pause_reason)),
      status_reason: Map.get(status, :reason),
      rejection: if(is_map(latest), do: Map.get(latest, :rejection)),
      expiry: if(is_map(latest), do: Map.get(latest, :expiry))
    }
  end

  defp report_resume(status, :applied) do
    IO.puts("aiur: resumed #{display_identifier(status)} (was: #{resumed_from(status)})")
    :ok
  end

  defp report_resume(status, detail) do
    print_unapplied_resume(status, detail)
    {:error, {:resume_unconfirmed, detail}}
  end

  # A `:running` row that took the queued-resume path had a pause the read
  # model had not yet shown as applied.
  defp resumed_from(%{state: :paused}), do: "paused"
  defp resumed_from(_status), do: "pausing"

  defp print_unapplied_resume(status, {:declined, detail}) do
    control_error("aiur: resume declined for #{display_identifier(status)}; #{held_control_detail(detail)}; #{control_rejection_detail(detail)}")
  end

  defp print_unapplied_resume(status, {:dropped, detail}) do
    control_error("aiur: resume request accepted for #{display_identifier(status)} but the resume dropped (#{dropped_resume_detail(detail)}); #{held_control_detail(detail)}")
  end

  defp print_unapplied_resume(status, {:unknown, detail}) do
    control_error(
      "aiur: resume request accepted for #{display_identifier(status)} but why it was not applied could not be determined (#{unknown_resume_detail(detail)}); #{held_control_detail(detail)}; outcome is unknown"
    )
  end

  defp held_control_detail(detail) do
    status = Map.get(detail, :control_status, :unknown)
    "control status remains #{status} (pause condition: #{pause_condition(detail)})"
  end

  defp pause_condition(%{status_reason: {:paused, :max_agent_duration}}), do: "maximum agent duration reached"
  defp pause_condition(%{pause_reason: :max_agent_duration}), do: "maximum agent duration reached"
  defp pause_condition(%{status_reason: reason}) when not is_nil(reason), do: StatusReason.render(reason)
  defp pause_condition(%{pause_reason: reason}) when not is_nil(reason), do: StatusReason.render(StatusReason.for_pause(reason))
  defp pause_condition(_detail), do: "unknown"

  defp control_rejection_detail(%{rejection: %{message: message}}) when is_binary(message), do: message
  defp control_rejection_detail(%{rejection: %{class: class}}), do: Reasons.format_reason(class)
  defp control_rejection_detail(_detail), do: "declining rule was not reported"

  defp dropped_resume_detail(%{expiry: %{reason: :timeout}}), do: "timeout"
  defp dropped_resume_detail(%{expiry: %{reason: reason}}), do: Reasons.format_reason(reason)
  defp dropped_resume_detail(_detail), do: "drop reason was not reported"

  defp unknown_resume_detail(%{reason: {:status_unreadable, error}}), do: "status unreadable: #{Reasons.format_reason(error)}"

  defp unknown_resume_detail(%{reason: reason}) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp unknown_resume_detail(%{reason: reason}) when not is_nil(reason), do: Reasons.format_reason(reason)
  defp unknown_resume_detail(_detail), do: "no diagnostic was reported"

  defp resume_confirm_timeout_ms do
    Application.get_env(:aiur, :agent_control_cli_resume_confirm_timeout_ms, @resume_confirm_timeout_ms)
  end
end
