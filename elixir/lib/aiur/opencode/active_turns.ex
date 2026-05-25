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
    ensure_table()
    :ets.insert(@table, {{identifier, aiur_turn_id}, :active})
    :ok
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
    ensure_table()
    :ets.insert(@table, {{identifier, aiur_turn_id}, {:closed, reason}})
    schedule_cleanup({identifier, aiur_turn_id})
    :ok
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
      [{_, state}] -> state
      [] -> :not_found
    end
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:cleanup, key}, state) do
    :ets.delete(@table, key)
    {:noreply, state}
  end

  defp schedule_cleanup(key) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> Process.send_after(pid, {:cleanup, key}, @cleanup_after_ms)
      _ -> :ok
    end

    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _tid -> @table
    end
  end
end
