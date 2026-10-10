defmodule Aiur.AgentRunner.NoopWait do
  @moduledoc """
  U4-T02: park a worker whose turn changed nothing observable instead of
  re-prompting it. A no-op turn is handed off if a rework push is waiting,
  otherwise the worker waits in `QueueDrain.wait_for_operator_message/6` until
  a queued ticket event or operator message arrives, then continues normally.

  The consecutive-no-op count survives the wake, so `max_consecutive_noop_turns`
  stays the outer bound on wakes that still produce nothing.
  """

  require Logger

  alias Aiur.AgentRunner.{QueueDrain, TurnLoop, TurnProgress}

  @spec park(map(), map(), fun(), Aiur.Issue.t(), TurnProgress.t()) ::
          :ok | {:completed, Aiur.Issue.t()} | {:error, term()}
  def park(turn_context, app_session, message_handler, issue, progress) do
    case TurnLoop.transition_agent_handoff(turn_context, issue) do
      {:handoff, result} ->
        result

      :none ->
        Logger.info("Turn changed nothing observable for #{Aiur.AgentRunner.issue_context(issue)}; waiting for a ticket event or operator message noop_turns=#{progress.consecutive_noops}")

        turn_context =
          turn_context
          |> Map.merge(%{issue: issue, noop_parked: true})
          |> Map.update!(:opts, &Keyword.put(&1, :turn_progress, progress))

        with :ok <-
               QueueDrain.wait_for_operator_message(
                 app_session,
                 issue,
                 message_handler,
                 turn_context.orchestrator,
                 turn_context.codex_update_recipient,
                 turn_context.opts
               ) do
          TurnLoop.continue_after_resume(turn_context, app_session)
        end
    end
  end

  @doc "Progress a resume starts from: kept across a no-op park, otherwise fresh."
  @spec progress_after_resume(map()) :: TurnProgress.t()
  def progress_after_resume(%{noop_parked: true, opts: opts}), do: TurnProgress.from_opts(opts)
  def progress_after_resume(_turn_context), do: TurnProgress.empty()
end
