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

  ## Runner generations

  A monitor-backed lease spans one runner's complete workspace and session
  lifetime. Duplicate runners wait on the exact incumbent lease instead of a
  momentary empty-turn boundary, while owner `DOWN` cleanup closes leaked turn
  entries before releasing parked duplicates.
  """

  use GenServer

  alias Aiur.AgentPubSub

  @table __MODULE__
  @cleanup_after_ms 60_000

  @type state :: :active | {:closed, term()} | :not_found
  @type generation_token :: reference()

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

      call_or_fallback(
        {:put, identifier, aiur_turn_id, self()},
        fn -> put_direct(identifier, aiur_turn_id) end
      )
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
    with_identifier_lock(identifier, fn ->
      ensure_table()

      call_or_fallback(
        {:mark_closed, identifier, aiur_turn_id, reason},
        fn -> mark_closed_direct(identifier, aiur_turn_id, reason) end
      )
    end)
  end

  @doc """
  Acquire the runner/session generation lease for `identifier`.

  Exactly one runner owns the lease at a time. The owner is monitored so a
  brutal task exit releases the lease and closes any active turns it left
  behind.
  """
  @spec acquire_generation(String.t()) ::
          {:ok, generation_token()} | {:error, {:generation_active, generation_token()}}
  def acquire_generation(identifier) when is_binary(identifier) do
    with_identifier_lock(identifier, fn ->
      GenServer.call(__MODULE__, {:acquire_generation, identifier, self()})
    end)
  end

  @doc "Release a runner/session generation lease owned by the caller."
  @spec release_generation(String.t(), generation_token()) :: :ok
  def release_generation(identifier, token)
      when is_binary(identifier) and is_reference(token) do
    with_identifier_lock(identifier, fn ->
      GenServer.call(__MODULE__, {:release_generation, identifier, token, self()})
    end)
  end

  @doc "Wait for the exact incumbent runner/session generation to finish."
  @spec await_generation(String.t(), generation_token()) :: :ok
  def await_generation(identifier, token)
      when is_binary(identifier) and is_reference(token) do
    GenServer.call(__MODULE__, {:await_generation, identifier, token}, :infinity)
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

  This is retained for callers that need a turn-boundary wait. Duplicate
  runners use `await_generation/2` instead so between-turn and paused-session
  gaps cannot release them early.
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
    {:ok, empty_state()}
  end

  @impl true
  def handle_call({:acquire_generation, identifier, owner}, _from, state) do
    case Map.get(state.generation_leases, identifier) do
      nil ->
        token = make_ref()

        state =
          state
          |> ensure_owner_monitor(owner)
          |> put_generation_lease(identifier, token, owner)

        {:reply, {:ok, token}, state}

      %{token: token} ->
        {:reply, {:error, {:generation_active, token}}, state}
    end
  end

  def handle_call({:release_generation, identifier, token, owner}, _from, state) do
    state = release_generation_lease(state, identifier, token, owner)
    {:reply, :ok, state}
  end

  def handle_call({:await_generation, identifier, token}, from, state) do
    case Map.get(state.generation_leases, identifier) do
      %{token: ^token} ->
        waiters =
          Map.update(state.generation_waiters, identifier, [{from, token}], fn waiters ->
            [{from, token} | waiters]
          end)

        {:noreply, %{state | generation_waiters: waiters}}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:put, identifier, aiur_turn_id, owner}, _from, state) do
    key = {identifier, aiur_turn_id}
    :ets.insert(@table, {key, :active, nil})

    state =
      state
      |> forget_turn_owner(key)
      |> ensure_owner_monitor(owner)
      |> put_turn_owner(key, owner)

    {:reply, :ok, state}
  end

  def handle_call({:mark_closed, identifier, aiur_turn_id, reason}, _from, state) do
    key = {identifier, aiur_turn_id}
    mark_closed_entry(key, reason)

    state =
      state
      |> forget_turn_owner(key)
      |> reply_inactive_waiters_if_clear(identifier)

    {:reply, :ok, state}
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
    {:noreply, forget_turn_owner(state, key)}
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

  def handle_info({:DOWN, ref, :process, owner, reason}, state) do
    case Map.get(state.owner_refs, ref) do
      ^owner -> {:noreply, release_owner(state, owner, ref, reason)}
      _other -> {:noreply, state}
    end
  end

  defp empty_state do
    %{
      generation_leases: %{},
      generation_waiters: %{},
      inactive_waiters: %{},
      owner_refs: %{},
      owners: %{},
      turn_owners: %{}
    }
  end

  defp ensure_owner_monitor(state, owner) do
    case Map.get(state.owners, owner) do
      nil ->
        ref = Process.monitor(owner)
        owner_state = %{generations: MapSet.new(), ref: ref, turns: MapSet.new()}

        %{
          state
          | owner_refs: Map.put(state.owner_refs, ref, owner),
            owners: Map.put(state.owners, owner, owner_state)
        }

      _owner_state ->
        state
    end
  end

  defp put_generation_lease(state, identifier, token, owner) do
    owner_state = Map.fetch!(state.owners, owner)
    owner_state = %{owner_state | generations: MapSet.put(owner_state.generations, identifier)}

    %{
      state
      | generation_leases: Map.put(state.generation_leases, identifier, %{owner: owner, token: token}),
        owners: Map.put(state.owners, owner, owner_state)
    }
  end

  defp put_turn_owner(state, key, owner) do
    owner_state = Map.fetch!(state.owners, owner)
    owner_state = %{owner_state | turns: MapSet.put(owner_state.turns, key)}

    %{
      state
      | owners: Map.put(state.owners, owner, owner_state),
        turn_owners: Map.put(state.turn_owners, key, owner)
    }
  end

  defp release_generation_lease(state, identifier, token, owner) do
    case Map.get(state.generation_leases, identifier) do
      %{owner: ^owner, token: ^token} ->
        state
        |> Map.update!(:generation_leases, &Map.delete(&1, identifier))
        |> update_owner(owner, fn owner_state ->
          %{owner_state | generations: MapSet.delete(owner_state.generations, identifier)}
        end)
        |> maybe_drop_owner_monitor(owner)
        |> reply_generation_waiters(identifier, token)

      _other ->
        state
    end
  end

  defp forget_turn_owner(state, key) do
    case Map.pop(state.turn_owners, key) do
      {nil, _turn_owners} ->
        state

      {owner, turn_owners} ->
        state
        |> Map.put(:turn_owners, turn_owners)
        |> update_owner(owner, fn owner_state ->
          %{owner_state | turns: MapSet.delete(owner_state.turns, key)}
        end)
        |> maybe_drop_owner_monitor(owner)
    end
  end

  defp update_owner(state, owner, update) do
    case Map.fetch(state.owners, owner) do
      {:ok, owner_state} -> %{state | owners: Map.put(state.owners, owner, update.(owner_state))}
      :error -> state
    end
  end

  defp maybe_drop_owner_monitor(state, owner) do
    case Map.get(state.owners, owner) do
      %{generations: generations, turns: turns, ref: ref} ->
        if MapSet.size(generations) == 0 and MapSet.size(turns) == 0 do
          Process.demonitor(ref, [:flush])

          %{
            state
            | owner_refs: Map.delete(state.owner_refs, ref),
              owners: Map.delete(state.owners, owner)
          }
        else
          state
        end

      _other ->
        state
    end
  end

  defp reply_generation_waiters(state, identifier, token) do
    {waiters, generation_waiters} = Map.pop(state.generation_waiters, identifier, [])
    {ready, remaining} = Enum.split_with(waiters, fn {_from, waiter_token} -> waiter_token == token end)

    Enum.each(ready, fn {from, _token} -> GenServer.reply(from, :ok) end)

    generation_waiters =
      if remaining == [],
        do: generation_waiters,
        else: Map.put(generation_waiters, identifier, remaining)

    %{state | generation_waiters: generation_waiters}
  end

  defp reply_inactive_waiters_if_clear(state, identifier) do
    case {active_turn_ids(identifier), Map.pop(state.inactive_waiters, identifier)} do
      {[], {waiters, remaining}} when is_list(waiters) ->
        Enum.each(waiters, &GenServer.reply(&1, :ok))
        %{state | inactive_waiters: remaining}

      _other ->
        state
    end
  end

  defp release_owner(state, owner, ref, reason) do
    case Map.get(state.owners, owner) do
      %{generations: generations, turns: turns} ->
        state = %{
          state
          | owner_refs: Map.delete(state.owner_refs, ref),
            owners: Map.delete(state.owners, owner)
        }

        state =
          Enum.reduce(turns, state, fn {identifier, _aiur_turn_id} = key, acc ->
            release_owned_turn_after_down(acc, key, identifier, owner, reason)
          end)

        Enum.reduce(generations, state, fn identifier, acc ->
          release_owned_generation_after_down(acc, identifier, owner)
        end)

      _other ->
        state
    end
  end

  defp release_owned_generation_after_down(state, identifier, owner) do
    case Map.get(state.generation_leases, identifier) do
      %{owner: ^owner, token: token} ->
        state
        |> Map.update!(:generation_leases, &Map.delete(&1, identifier))
        |> reply_generation_waiters(identifier, token)

      _other ->
        state
    end
  end

  defp release_owned_turn_after_down(state, key, identifier, owner, reason) do
    case Map.get(state.turn_owners, key) do
      ^owner ->
        close_reason = {:failed, {:owner_down, reason}}
        mark_closed_entry(key, close_reason)
        AgentPubSub.broadcast_aiur_turn_done(identifier, elem(key, 1), close_reason)

        state
        |> Map.update!(:turn_owners, &Map.delete(&1, key))
        |> reply_inactive_waiters_if_clear(identifier)

      _other ->
        state
    end
  end

  defp put_direct(identifier, aiur_turn_id) do
    :ets.insert(@table, {{identifier, aiur_turn_id}, :active, nil})
    :ok
  end

  defp mark_closed_direct(identifier, aiur_turn_id, reason) do
    mark_closed_entry({identifier, aiur_turn_id}, reason)
    notify_inactive_waiters(identifier)
  end

  defp mark_closed_entry(key, reason) do
    prior_pid = current_subscriber_pid(key)
    :ets.insert(@table, {key, {:closed, reason}, prior_pid})
    schedule_cleanup(key)
    :ok
  end

  defp call_or_fallback(message, fallback) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, message)
      _other -> fallback.()
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
