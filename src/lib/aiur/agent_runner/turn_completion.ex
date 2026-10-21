defmodule Aiur.AgentRunner.TurnCompletion do
  @moduledoc false

  require Logger
  alias Aiur.AgentCompaction.Handoff
  alias Aiur.AgentRunner.{NoopWait, ReworkHandoff, ReworkHandoffGuard, TurnAlerts, TurnLoop, TurnProgress}
  alias Aiur.{Config, Issue}
  alias Aiur.GitHub.Client, as: GitHubClient
  alias Aiur.Orchestrator.{DispatchPolicy, ReworkGate, TicketTransition}

  @spec finalize_turn_completion(map(), map(), map(), fun()) :: term()
  def finalize_turn_completion(turn_context, app_session, turn_session, message_handler) do
    %{
      workspace: workspace,
      issue: issue,
      issue_state_fetcher: issue_state_fetcher,
      turn_number: turn_number,
      max_turns: max_turns
    } = turn_context

    Logger.info(
      "Completed agent run for #{Aiur.AgentRunner.issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{TurnLoop.max_turns_display(max_turns)}"
    )

    case TurnLoop.continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when is_nil(max_turns) or turn_number < max_turns ->
        ReworkHandoff.after_turn(refreshed_issue, turn_context, fn ->
          continue_unless_noop_bound(turn_context, app_session, refreshed_issue, message_handler)
        end)

      {:continue, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=max_turns_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number}/#{max_turns}")

        Logger.info("Reached agent.max_turns for #{Aiur.AgentRunner.issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        stop_on_turn_limit(turn_context, refreshed_issue)

      {:done, refreshed_issue} ->
        Logger.info("aiur_autonomous_loop phase=done elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} reason=issue_inactive")

        Handoff.run(turn_context, app_session, refreshed_issue)
        TurnLoop.return_completed(turn_context, refreshed_issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # #2806: fold turn progress into the no-op counter and stop without mutating
  # the ticket once an unproductive run reaches its cap. Productive turns reset it.
  defp continue_unless_noop_bound(turn_context, app_session, refreshed_issue, message_handler) do
    %{
      workspace: workspace,
      worker_host: worker_host,
      opts: opts,
      turn_number: turn_number,
      max_turns: max_turns,
      prompt: prompt
    } = turn_context

    witness = TurnProgress.witness(prompt, workspace, worker_host, refreshed_issue, opts)
    {verdict, progress} = TurnProgress.observe(TurnProgress.from_opts(opts), witness)
    cap = noop_turn_cap(opts)

    cond do
      verdict == :noop and is_integer(cap) and progress.consecutive_noops >= cap ->
        stop_on_noop_bound(turn_context, refreshed_issue, progress, witness, cap)

      verdict == :noop ->
        NoopWait.park(turn_context, app_session, message_handler, refreshed_issue, progress)

      true ->
        Logger.info(
          "aiur_autonomous_loop phase=recurse elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number + 1}/#{TurnLoop.max_turns_display(max_turns)} reason=turn_completed noop_turns=#{progress.consecutive_noops}"
        )

        Logger.info("Continuing agent run for #{Aiur.AgentRunner.issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{TurnLoop.max_turns_display(max_turns)}")

        TurnLoop.continue_issue_turn(
          %{
            turn_context
            | issue: refreshed_issue,
              turn_number: turn_number + 1,
              opts: Keyword.put(opts, :turn_progress, progress)
          },
          app_session
        )
    end
  end

  # The bound must leave a durable record, not a bare `Logger.info` (#2797): a
  # ticket-scoped needs-attention alert naming the ticket, the count, and the
  # state label that kept the loop alive. A rework run whose head is newer than
  # its blocking review gets a review handoff (#3971); one with no push fails.
  defp stop_on_noop_bound(turn_context, refreshed_issue, progress, witness, cap) do
    %{turn_number: turn_number, max_turns: max_turns} = turn_context

    Logger.warning(
      "aiur_autonomous_loop phase=noop_bound_reached elapsed_ms=#{Aiur.Boot.elapsed_ms()} identifier=#{refreshed_issue.identifier} turn=#{turn_number}/#{TurnLoop.max_turns_display(max_turns)} noop_turns=#{progress.consecutive_noops} cap=#{cap}"
    )

    case noop_handoff(turn_context, refreshed_issue) do
      {:handoff, result} ->
        result

      :none ->
        complete_noop_bound_without_handoff(turn_context, refreshed_issue, progress, witness, cap)
    end
  end

  @doc "Handoff for a no-op turn; the bound and the park share these opts (#3971)."
  @spec noop_handoff(map(), Aiur.Issue.t()) :: {:handoff, term()} | :none | {:error, term()}
  def noop_handoff(turn_context, issue) do
    opts = Keyword.put(turn_context.opts, :superseded_review_handoff?, noop_failure_state(issue) == "error")
    transition_agent_handoff(%{turn_context | opts: opts}, issue)
  end

  defp complete_noop_bound_without_handoff(turn_context, issue, progress, witness, cap) do
    %{workspace: workspace, worker_host: worker_host, turn_number: turn_number} = turn_context

    case noop_failure_state(issue) do
      nil ->
        emit_noop_bound_alert(issue, workspace, worker_host, progress, witness, cap, turn_number)
        TurnLoop.return_completed(turn_context, issue)

      state_name ->
        case TicketTransition.write_state(issue.identifier, state_name, writer: :turn_loop) do
          :ok ->
            failed_issue = %{issue | state: state_name}
            emit_noop_bound_alert(failed_issue, workspace, worker_host, progress, witness, cap, turn_number)
            TurnLoop.return_completed(turn_context, failed_issue)

          {:error, reason} ->
            {:error, {:noop_bound_state_write_failed, reason}}
        end
    end
  end

  defp emit_noop_bound_alert(issue, workspace, worker_host, progress, witness, cap, turn_number) do
    TurnAlerts.emit_noop_turn_bound_alert(issue, workspace, worker_host, %{
      consecutive_noops: progress.consecutive_noops,
      cap: cap,
      turn_number: turn_number,
      unchanged: TurnProgress.unchanged_witnesses(witness)
    })
  end

  defp stop_on_turn_limit(turn_context, refreshed_issue) do
    case transition_agent_handoff(turn_context, refreshed_issue) do
      {:handoff, result} -> result
      :none -> TurnLoop.return_completed(turn_context, refreshed_issue)
    end
  end

  @doc false
  @spec transition_agent_handoff(map(), Issue.t()) :: {:handoff, term()} | :none | {:error, term()}
  def transition_agent_handoff(turn_context, refreshed_issue) do
    %{workspace: workspace, worker_host: worker_host, opts: opts} = turn_context

    case stopped_agent_handoff(refreshed_issue, workspace, worker_host, opts) do
      {:handoff, state} ->
        handoff_after_evidence_check(turn_context, refreshed_issue, state, workspace, worker_host, opts)

      :none ->
        :none
    end
  end

  defp handoff_after_evidence_check(turn_context, issue, state, workspace, worker_host, opts) do
    case ReworkHandoffGuard.evidence_blockers(issue, state, workspace, opts) do
      :allow ->
        case TicketTransition.write_state(issue.identifier, state, writer: :turn_loop) do
          :ok ->
            TurnAlerts.emit_rework_handoff_alert(issue, workspace, worker_host, state)
            {:handoff, TurnLoop.return_completed(turn_context, %{issue | state: state})}

          {:error, reason} ->
            {:error, {:rework_handoff_state_write_failed, reason}}
        end

      {:refused, reason, message} ->
        {:error, {:rework_handoff_evidence_refused, reason, message}}
    end
  end

  defp stopped_agent_handoff(issue, workspace, worker_host, opts) do
    ReworkGate.stopped_agent_handoff(issue.identifier, Keyword.get(opts, :rework_head_sha),
      open_pr_fetcher: Keyword.get(opts, :open_pr_fetcher, &Aiur.CodeHost.fetch_open_pull_request_for_branch/1),
      commit_ci_status_fetcher: Keyword.get(opts, :commit_ci_status_fetcher, &GitHubClient.fetch_commit_ci_status/1),
      superseded_review_handoff?: Keyword.get(opts, :superseded_review_handoff?, false),
      reviews_fetcher: Keyword.get(opts, :reviews_fetcher),
      workspace: workspace,
      worker_host: worker_host
    )
  end

  defp noop_failure_state(issue) do
    case DispatchPolicy.normalize_issue_state(issue.state) do
      "rework" -> "error"
      _ -> nil
    end
  end

  # nil / 0 disables the bound, matching how `agent.max_turns` reads "uncapped".
  @doc false
  @spec noop_turn_cap(keyword()) :: pos_integer() | nil
  def noop_turn_cap(opts) do
    opts
    |> Keyword.get(:max_consecutive_noop_turns, Config.agent_max_consecutive_noop_turns())
    |> case do
      cap when is_integer(cap) and cap > 0 -> cap
      _disabled -> nil
    end
  end
end
