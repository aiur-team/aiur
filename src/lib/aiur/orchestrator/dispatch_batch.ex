defmodule Aiur.Orchestrator.DispatchBatch do
  @moduledoc """
  Pacing and completion of the candidate dispatch batch.

  `Dispatcher.choose_issues/3` validates candidates one at a time as an
  asynchronous chain. Before each candidate the batch checks that the owner can
  keep up:

    * a stale load sample stops the batch, so it never admits work on a figure
      that no longer describes the host (#3528); the next poll resumes;
    * a deep owner mailbox is transient (a burst of webhook deliveries or task
      results), so the batch yields to let the owner drain it and then resumes
      at the same candidate. Ending the batch there left eligible tickets
      unstarted with free slots for a full poll interval, and recorded no
      reason (#3683). Only an owner process can drain, and yields are bounded.

  When the batch ends, `finish/3` hands the final state and the stop reason
  (or `nil`) to the `:dispatch_chain_done_fun` option, so the cycle's outcome
  is judged on what the chain did rather than on the state when it started.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Orchestrator.{State, TrackerTasks}

  @mailbox_limit 100
  @yield_ms 200
  @max_yields 25

  @type stop_reason :: :orchestrator_backlog | :stale_load_sample | nil

  @doc """
  Runs `ready_fun` when the batch may take the next candidate. Otherwise yields
  through `resume_fun` (given the state and updated options) or stops the batch.
  """
  @spec advance(State.t(), [Aiur.Issue.t(), ...], keyword(), (-> State.t()), (State.t(), keyword() -> State.t())) :: State.t()
  def advance(%State{} = state, [next | _] = remaining, opts, ready_fun, resume_fun) do
    case readiness(state) do
      :ready ->
        ready_fun.()

      :orchestrator_backlog ->
        yield_or_stop(state, remaining, next, opts, resume_fun)

      :stale_load_sample ->
        stop(state, remaining, next, opts, :stale_load_sample)
    end
  end

  @doc "Ends the batch and reports its outcome to `:dispatch_chain_done_fun`, if given."
  @spec finish(State.t(), keyword(), stop_reason()) :: State.t()
  def finish(%State{} = state, opts, stop_reason) do
    case Keyword.get(opts, :dispatch_chain_done_fun) do
      done when is_function(done, 2) -> done.(state, stop_reason)
      _none -> state
    end
  end

  defp yield_or_stop(state, remaining, next, opts, resume_fun) do
    yields = Keyword.get(opts, :dispatch_batch_yields, 0)

    if TrackerTasks.owner?(state) and yields < @max_yields do
      yield_ms = Keyword.get(opts, :dispatch_batch_yield_ms, @yield_ms)
      resume_opts = Keyword.put(opts, :dispatch_batch_yields, yields + 1)
      TrackerTasks.start(state, {:dispatch, :batch_yield}, fn -> Process.sleep(yield_ms) end, fn current, _ -> resume_fun.(current, resume_opts) end)
    else
      stop(state, remaining, next, opts, :orchestrator_backlog)
    end
  end

  defp stop(state, remaining, next, opts, reason) do
    Logger.info("orchestrator.dispatch batch stopped reason=#{reason} remaining=#{length(remaining)} next=#{next.identifier}")
    finish(state, opts, reason)
  end

  defp readiness(state) do
    {:message_queue_len, depth} = Process.info(self(), :message_queue_len)

    cond do
      not load_sample_current?(state) -> :stale_load_sample
      depth >= @mailbox_limit -> :orchestrator_backlog
      true -> :ready
    end
  end

  defp load_sample_current?(state) do
    sampled_at_ms = Map.get(state.load_envelope_state, :sampled_at_ms)
    period_ms = state.poll_interval_ms || Aiur.PollCadence.base_interval_ms(class: :dispatch)

    not Map.has_key?(state.load_envelope_state, :sampled_at_ms) or is_nil(Config.target_load_average()) or
      (is_integer(sampled_at_ms) and System.monotonic_time(:millisecond) - sampled_at_ms <= period_ms)
  end
end
