defmodule Aiur.Opencode.ActiveTurns do
  @moduledoc """
  Live registry of `(identifier, aiur_turn_id)` pairs for the
  bridge-as-LLM stream. `Aiur.AgentRunner` puts an entry as `:active`
  before posting the `__aiur_turn__:<id>` marker to opencode and marks
  it `{:closed, reason}` after `CodingAgent.run_turn` returns.
  `Aiur.Opencode.ChatCompletions.stream_codex_turn/3` checks the entry
  before entering the receive loop so it can recognize phantom
  chat-completions (opencode-serve replaying an unanswered marker from
  a prior aiur boot — its SQLite outlives our process) and close them
  immediately instead of waiting on a broadcast that will never arrive.

  Entries linger for `@cleanup_after_ms` after `mark_closed/3` so a
  bridge that subscribes slightly after the close broadcast still
  observes `{:closed, reason}` and finalizes cleanly with the actual
  finish reason rather than the 10-minute watchdog message.

  ## Subscriber displacement

  Each entry also tracks the pid of the single bridge process that
  owns the live SSE stream. `register_subscriber/3` atomically swaps
  the pid and returns whatever pid was there before, so the caller can
  tell the old bridge to finalize. Opencode periodically reconnects
  the chat-completion HTTP request (read timeout, ~30s of silence) and
  without displacement every reconnect grows another subscriber on the
  agent's PubSub topic — each new broadcast fans out N copies into the
  chat pane.
  """

  use GenServer

  @table __MODULE__
  @cleanup_after_ms 60_000

  @type state :: :active | {:closed, term()} | :not_found

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register `(identifier, aiur_turn_id)` as `:active`. Call this BEFORE
  posting the marker — that way the bridge always observes the entry
  when it handles the resulting chat-completion request.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(identifier, aiur_turn_id)
      when is_binary(identifier) and is_binary(aiur_turn_id) do
    with_identifier_lock(identifier, fn ->
      ensure_table()
      :ets.insert(@table, {{identifier, aiur_turn_id}, :active, nil})
      :ok
    end)
  end

  @doc """
  Mark `(identifier, aiur_turn_id)` `{:closed, reason}` and schedule
  the entry's removal after the cleanup window. Bridges that subscribe
  during the window observe `{:closed, reason}` and finalize the SSE
  with the recorded reason.
  """
  @spec mark_closed(String.t(), String.t(), term()) :: :ok
  def mark_closed(identifier, aiur_turn_id, reason)
      when is_binary(identifier) and is_binary(aiur_turn_id) do
    :ok =
      with_identifier_lock(identifier, fn ->
        ensure_table()
        prior_pid = current_subscriber_pid({identifier, aiur_turn_id})
        :ets.insert(@table, {{identifier, aiur_turn_id}, {:closed, reason}, prior_pid})
        schedule_cleanup({identifier, aiur_turn_id})
        :ok
      end)

    notify_inactive_waiters(identifier)
  end

  @doc """
  Runs a workspace operation while no turn for `identifier` is active.

  Turn activation and closure use the same per-identifier lock, so the empty
  check and the operation form one critical section without serializing work
  for unrelated tickets.
  """
  @spec with_inactive_turn(String.t(), (-> result)) :: {:ok, result} | {:error, :active_turn}
        when result: term()
  def with_inactive_turn(identifier, operation)
      when is_binary(identifier) and is_function(operation, 0) do
    with_identifier_lock(identifier, fn ->
      case active_turn_ids(identifier) do
        [] -> {:ok, operation.()}
        _turn_ids -> {:error, :active_turn}
      end
    end)
  end

  @doc """
  Wait until every live turn for `identifier` has closed.

  A duplicate runner uses this after workspace setup returns
  `{:defer, :active_turn}`. Keeping that runner parked until the existing turn
  closes avoids both concurrent sessions and a tight continuation-dispatch
  loop.
  """
  @spec await_inactive(String.t()) :: :ok
  def await_inactive(identifier) when is_binary(identifier) do
    GenServer.call(__MODULE__, {:await_inactive, identifier}, :infinity)
  end

  @doc """
  Look up the recorded state for `(identifier, aiur_turn_id)`.
  `:not_found` means this aiur boot never registered the id — the
  bridge should treat the chat-completion as a phantom and close.
  """
  @spec lookup(String.t(), String.t()) :: state()
  def lookup(identifier, aiur_turn_id)
      when is_binary(identifier) and is_binary(aiur_turn_id) do
    ensure_table()

    case :ets.lookup(@table, {identifier, aiur_turn_id}) do
      [{_, state, _pid}] -> state
      [] -> :not_found
    end
  end

  @doc """
  Return every `aiur_turn_id` currently in `:active` state for the given
  `identifier`. Used by `Aiur.Opencode.SessionWriter` on `phase=ready` to
  catch up on in-flight aiur turns: when a session writer registers after
  the agent's codex turn has already started (the `--debug` session-resume
  race — replay takes ~6 s, codex turn fires markers at t=0 and finds
  zero writers), the writer needs to post a marker to its own session so
  the bridge sees the new chat-completion request and opens the live
  stream. Without this, the chat pane gets no live deltas for the rest
  of the run; content lands via SQL replay only.
  """
  @spec active_turn_ids(String.t()) :: [String.t()]
  def active_turn_ids(identifier) when is_binary(identifier) do
    ensure_table()

    :ets.foldl(
      fn
        {{^identifier, aiur_turn_id}, :active, _pid}, acc -> [aiur_turn_id | acc]
        _, acc -> acc
      end,
      [],
      @table
    )
  end

  @doc """
  Atomically claim the single subscriber slot for `(identifier,
  aiur_turn_id)`. Returns the pid that previously held the slot (or
  `nil` if none). Callers should send the returned pid a `:displaced`
  message so it stops streaming.

  Serialized through the GenServer so two concurrent reconnects can't
  both observe an empty slot and both write themselves into it.
  """
  @spec register_subscriber(String.t(), String.t(), pid()) :: {:ok, pid() | nil}
  def register_subscriber(identifier, aiur_turn_id, pid)
      when is_binary(identifier) and is_binary(aiur_turn_id) and is_pid(pid) do
    with_identifier_lock(identifier, fn ->
      GenServer.call(__MODULE__, {:register_subscriber, identifier, aiur_turn_id, pid})
    end)
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{inactive_waiters: %{}}}
  end

  @impl true
  def handle_call({:await_inactive, identifier}, from, state) do
    case active_turn_ids(identifier) do
      [] ->
        {:reply, :ok, state}

      _turn_ids ->
        waiters = Map.update(state.inactive_waiters, identifier, [from], &[from | &1])
        {:noreply, %{state | inactive_waiters: waiters}}
    end
  end

  @impl true
  def handle_call({:register_subscriber, identifier, aiur_turn_id, pid}, _from, state) do
    key = {identifier, aiur_turn_id}

    prior_pid =
      case :ets.lookup(@table, key) do
        [{_, turn_state, prior}] ->
          :ets.insert(@table, {key, turn_state, pid})
          prior

        [] ->
          :ets.insert(@table, {key, :active, pid})
          nil
      end

    {:reply, {:ok, prior_pid}, state}
  end

  @impl true
  def handle_info({:cleanup, key}, state) do
    :ets.delete(@table, key)
    {:noreply, state}
  end

  def handle_info({:turn_state_changed, identifier}, state) do
    case {active_turn_ids(identifier), Map.pop(state.inactive_waiters, identifier)} do
      {[], {waiters, remaining}} when is_list(waiters) ->
        Enum.each(waiters, &GenServer.reply(&1, :ok))
        {:noreply, %{state | inactive_waiters: remaining}}

      _other ->
        {:noreply, state}
    end
  end

  defp schedule_cleanup(key) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> Process.send_after(pid, {:cleanup, key}, @cleanup_after_ms)
      _ -> :ok
    end

    :ok
  end

  defp notify_inactive_waiters(identifier) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> send(pid, {:turn_state_changed, identifier})
      _ -> :ok
    end

    :ok
  end

  defp current_subscriber_pid(key) do
    case :ets.lookup(@table, key) do
      [{_, _state, pid}] -> pid
      [] -> nil
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _tid -> @table
    end
  end

  defp with_identifier_lock(identifier, operation) do
    :global.trans({{__MODULE__, identifier}, self()}, operation)
  end
end
