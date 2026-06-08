defmodule Aiur.Opencode.TokenRegistry do
  @moduledoc """
  Token validity store for the opencode bridge.

  Each opencode-serve instance has its own bearer token baked into the
  workspace's `opencode.json`. When the bridge (`/v1/chat/completions`)
  receives a chat-completion request, it reads the bearer token off the
  request and asks this registry whether the token is currently valid.

  Token entries are keyed by token alone — NOT by identifier. The
  bridge routes the request to an agent identifier via the request
  body's `model` field (`identifier_from_model/1`), so this registry's
  only job is "is this bearer a live workspace?".

  ## Generation counter (slot serve restart overlap)

  Each token entry carries `{slot_index, generation}`. The generation
  increments every time a slot restarts its opencode-serve. The strict
  overlap order avoids any empty-registry window during restart:

      slot.bump_generation()              # gen N -> N+1
      put(new_token, slot, N+1)           # new token now valid
      Server.start_link(...)              # new serve boots
      ...wait for attach ready...
      delete_stale(slot, N+1)             # sweep gen < N+1

  Between the `put` and `delete_stale` calls both old and new tokens
  validate, so a chat-completion request arriving mid-restart never
  sees an unauthorized window.
  """

  use GenServer

  @table __MODULE__

  @type slot_index :: pos_integer()
  @type generation :: pos_integer()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Mark `token` valid. Stores `{slot_index, generation, inserted_at}`
  so `delete_stale/2` can sweep older generations after a slot serve
  restart.
  """
  @spec put(String.t(), slot_index(), generation()) :: :ok
  def put(token, slot_index, generation)
      when is_binary(token) and is_integer(slot_index) and is_integer(generation) do
    ensure_table()
    :ets.insert(@table, {token, {slot_index, generation, System.monotonic_time(:millisecond)}})
    :ok
  end

  @doc """
  Remove a single token regardless of slot/generation. Used when a slot
  is being torn down entirely (e.g. on aiur shutdown).
  """
  @spec delete(String.t()) :: :ok
  def delete(token) when is_binary(token) do
    ensure_table()
    :ets.delete(@table, token)
    :ok
  end

  @doc """
  Remove every token entry for `slot_index` whose recorded generation
  is strictly less than `current_generation`. Called by a slot AFTER
  its new opencode-serve + attach are fully ready, so old tokens
  remain valid for the brief overlap window during restart.
  """
  @spec delete_stale(slot_index(), generation()) :: :ok
  def delete_stale(slot_index, current_generation)
      when is_integer(slot_index) and is_integer(current_generation) do
    ensure_table()

    :ets.foldl(
      fn
        {token, {^slot_index, gen, _ts}}, _acc when gen < current_generation ->
          :ets.delete(@table, token)
          :ok

        _entry, _acc ->
          :ok
      end,
      :ok,
      @table
    )

    :ok
  end

  @doc """
  Returns true if `token` is currently registered (any slot, any
  generation). The caller is responsible for extracting the agent
  identifier from the request body separately — token validity alone
  authorizes; routing is independent.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(token) when is_binary(token) do
    ensure_table()
    :ets.member(@table, token)
  end

  @doc """
  Returns `{:ok, slot_index}` for a registered token, or `:not_found`.
  Used by the chat-completion bridge to identify which slot's serve
  issued the request so it can look up the right per-slot SessionWriter.
  """
  @spec lookup_slot(String.t()) :: {:ok, slot_index()} | :not_found
  def lookup_slot(token) when is_binary(token) do
    ensure_table()

    case :ets.lookup(@table, token) do
      [{^token, {slot_index, _gen, _ts}}] -> {:ok, slot_index}
      _ -> :not_found
    end
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _tid -> @table
    end
  end
end
