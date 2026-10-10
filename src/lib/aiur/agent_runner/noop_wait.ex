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
    handoff = TurnLoop.transition_agent_handoff(turn_context, issue)

    case handoff do
      {:handoff, result} ->
        result

      other ->
        # A failed handoff write must not crash the worker; park instead and
        # let the bounded wait or the no-op cap retry it.
        with {:error, reason} <- other,
             do: Logger.warning("No-op handoff write failed for #{Aiur.AgentRunner.issue_context(issue)}: #{inspect(reason)}; parking instead")

        Logger.info("Turn changed nothing observable for #{Aiur.AgentRunner.issue_context(issue)}; waiting for a ticket event or operator message noop_turns=#{progress.consecutive_noops}")

        turn_context =
          turn_context
          |> Map.merge(%{issue: issue, noop_parked: true})
          |> Map.update!(:opts, &Keyword.put(&1, :turn_progress, progress))

        timer = arm_timeout(turn_context.opts)

        result =
          QueueDrain.wait_for_operator_message(
            app_session,
            issue,
            message_handler,
            turn_context.orchestrator,
            turn_context.codex_update_recipient,
            turn_context.opts
          )

        disarm_timeout(timer)
        with :ok <- result, do: TurnLoop.continue_after_resume(turn_context, app_session)
    end
  end

  # Bounded park: with no wake the worker would hold its slot until the stall
  # watchdog. On timeout it resumes with a normal turn; the surviving no-op
  # count then ends a still-idle ticket at `max_consecutive_noop_turns`.
  defp arm_timeout(opts) do
    case Keyword.get_lazy(opts, :noop_park_timeout_ms, &configured_timeout_ms/0) do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :noop_park_timeout, ms)
      _disabled -> nil
    end
  end

  defp configured_timeout_ms do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings.agent.noop_park_timeout_ms
      _unavailable -> nil
    end
  end

  defp disarm_timeout(timer) do
    if timer, do: Process.cancel_timer(timer)

    receive do
      :noop_park_timeout -> :ok
    after
      0 -> :ok
    end
  end

  @doc "Progress a resume starts from: kept across a no-op park, otherwise fresh."
  @spec progress_after_resume(map()) :: TurnProgress.t()
  def progress_after_resume(%{noop_parked: true, opts: opts}), do: TurnProgress.from_opts(opts)
  def progress_after_resume(_turn_context), do: TurnProgress.empty()
end
