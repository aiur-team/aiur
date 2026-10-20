defmodule Aiur.GitHub.Listeners.Comments do
  @moduledoc "Owns the comment cursor, reconcile timers, and owned-poll process protocol."
  use GenServer

  alias Aiur.GitHub.Listeners.Comments.{Cursor, Driver, Input, Reconcile}

  defstruct cursor: %Cursor{}, input: nil, opts: [], recipient: nil, recipient_ref: nil, pending_finish: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:reset, _from, state) do
    stop(state)
    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:start, input, opts}, state) do
    state = refresh(state, input, opts)
    {:noreply, if(state.pending_finish, do: state, else: run(state, :start_async, []))}
  end

  def handle_cast({:reconcile, hint, input, opts}, state) do
    state = refresh(state, input, opts)
    opts = if state.pending_finish, do: Keyword.put(state.opts, :poll_frozen, true), else: state.opts
    {cursor, _outcome} = Driver.request_reconcile(state.cursor, input, hint, opts)
    {:noreply, %{state | cursor: cursor}}
  end

  def handle_cast({:backoff, delay, completion, poll_opts}, %{input: %Input{} = input} = state) do
    state = %{state | input: %{input | next_github_delay_ms: delay}}

    next =
      case state.pending_finish do
        {^completion, outcome} -> finish(%{state | pending_finish: nil, opts: poll_opts || state.opts}, outcome)
        nil -> %{state | cursor: Reconcile.schedule(state.cursor, state.input, 0, false, state.opts)}
        _waiting_for_fold -> state
      end

    {:noreply, next}
  end

  def handle_cast({:backoff, _delay, _completion, _poll_opts}, state), do: {:noreply, state}

  @impl true
  def handle_info({:github_comments_polled, ref, payload}, %{cursor: %Cursor{poll: %{ref: ref}}} = state) do
    {cursor, outcome} = Driver.apply_async(state.cursor, state.input, ref, payload, state.opts)
    {:noreply, publish(%{state | cursor: cursor}, outcome)}
  end

  def handle_info({:github_comment_poll_started, ref, owner, pid}, %{input: %Input{}} = state),
    do: {:noreply, run(state, :apply_async_started, [ref, owner, pid])}

  def handle_info({:github_comment_poll_guarding, ref, owner, pid}, %{input: %Input{}} = state),
    do: {:noreply, run(state, :apply_async_guarding, [ref, owner, pid])}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{recipient_ref: ref} = state) do
    stop(state)
    {:noreply, %__MODULE__{}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{input: %Input{}} = state) do
    {cursor, outcome} = Driver.apply_async_down(state.cursor, state.input, ref, state.opts)
    next = %{state | cursor: cursor}
    {:noreply, if(outcome.handled?, do: publish(next, outcome), else: next)}
  end

  def handle_info({:run_github_comment_reconcile, token}, %{pending_finish: nil, input: %Input{}} = state),
    do: {:noreply, run(state, :run_scheduled_reconcile, [token])}

  def handle_info({:run_github_comment_reconcile, token}, %{cursor: %Cursor{reconcile_timer: %{token: token}}} = state),
    do: {:noreply, %{state | cursor: %{state.cursor | reconcile_timer: nil}}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop(state)

  defp refresh(state, input, opts) do
    recipient = Keyword.get(opts, :recipient, Aiur.Orchestrator)

    ref =
      if recipient == state.recipient do
        state.recipient_ref
      else
        if state.recipient_ref, do: Process.demonitor(state.recipient_ref, [:flush])
        Process.monitor(recipient)
      end

    %{state | input: input, opts: opts, recipient: recipient, recipient_ref: ref}
  end

  defp run(state, function, args) do
    {cursor, outcome} = apply(Driver, function, [state.cursor, state.input] ++ args ++ [state.opts])
    finish(%{state | cursor: cursor}, outcome)
  end

  # Retry scheduling waits for the orchestrator to fold connectivity and return its fresh backoff.
  defp publish(state, outcome) do
    completion = make_ref()
    send(state.recipient, {:github_listener_outcome, :comments, Map.put(outcome, :completion, completion)})
    %{state | pending_finish: {completion, outcome}}
  end

  defp finish(state, outcome), do: %{state | cursor: Driver.finish(state.cursor, state.input, outcome, state.opts)}

  defp stop(state) do
    if state.recipient_ref, do: Process.demonitor(state.recipient_ref, [:flush])
    cursor = state.cursor
    Driver.terminate_poll(cursor.poll)
    if cursor.reconcile_timer && cursor.reconcile_timer.timer_ref, do: Process.cancel_timer(cursor.reconcile_timer.timer_ref)
    :ok
  end
end
