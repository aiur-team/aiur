defmodule Aiur.Events.Exchange do
  @moduledoc """
  AMQP-topic-exchange-style routing for cross-ticket Aiur events.

  Coexists with `Aiur.PubSub` (Phoenix.PubSub for literal per-agent
  topics). Where PubSub matches topic strings exactly, this exchange
  matches binding **patterns** against event topics using
  `Aiur.Events.Topic.matches?/2` — supporting `*` (one segment) and
  `#` (zero-or-more) wildcards from RabbitMQ.

  ## Why a separate exchange

  Phoenix.PubSub does literal-only matching. Cross-ticket subscription
  needs patterns like `ticket.42.*.push` or `system.main.branch.#`,
  which PubSub cannot express. Rather than denormalize bindings into
  N literal topic subscriptions (the explosion grows with every issue
  + every surface + every verb), we maintain a small ETS table of
  `{pattern, pid}` bindings and walk it on every publish.

  ## ETS + GenServer model

  The GenServer owns a `:named_table, :public, :duplicate_bag` ETS
  table (`#{__MODULE__}.Bindings`). `subscribe/1` and `unsubscribe/1`
  go through the GenServer so that the monitor lifecycle stays serial,
  but `publish/2` reads ETS directly (public table) — the publisher
  is never serialized through the GenServer mailbox, so a slow handler
  cannot bottleneck event emission.

  Each binding row is `{pattern, subscriber_pid, monitor_ref}`. The
  GenServer monitors every subscriber and reaps stale rows on `:DOWN`
  so callers don't have to call `unsubscribe/1` before crashing.

  ## Async delivery

  `publish/2` does `send(pid, {:event, event})` — never `GenServer.call`,
  never `GenServer.cast` with backpressure. AMQP topic-exchange
  semantics are fire-and-forget; subscribers are responsible for
  draining their own mailboxes. The renderer + at-least-once cursor
  dedup contract upstream is what makes this safe.
  """

  use GenServer

  require Logger

  alias Aiur.Events.Topic

  @table __MODULE__.Bindings

  @typedoc """
  Event payload published through the exchange. Shape is opaque to
  this module — the only thing the exchange inspects is the topic
  string passed to `publish/2`.
  """
  @type event :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Subscribes the calling process to receive every event whose topic
  matches `pattern`. Returns `:ok` on success. Raises `ArgumentError`
  on a malformed pattern (empty string, leading/trailing dot, etc.).

  The exchange monitors the caller and reaps the binding when the
  subscriber dies.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(pattern) when is_binary(pattern) do
    validate_pattern!(pattern)
    GenServer.call(__MODULE__, {:subscribe, pattern, self()})
  end

  @doc """
  Removes a binding for `(pattern, calling pid)`. No-op if the binding
  doesn't exist.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(pattern) when is_binary(pattern) do
    GenServer.call(__MODULE__, {:unsubscribe, pattern, self()})
  end

  @doc """
  Publishes `event` to every binding whose pattern matches `topic`.
  Returns the count of subscribers that received it (useful for
  observability; not load-bearing).

  Reads ETS directly — does not go through the GenServer mailbox.
  """
  @spec publish(String.t(), event()) :: non_neg_integer()
  def publish(topic, event) when is_binary(topic) do
    :ets.foldl(
      fn {pattern, pid, _ref}, acc ->
        if Topic.matches?(pattern, topic) do
          send(pid, {:event, event})
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  @doc """
  Returns the list of patterns currently bound to `pid`. Mostly for
  tests and observability.
  """
  @spec bindings_for(pid()) :: [String.t()]
  def bindings_for(pid) when is_pid(pid) do
    @table
    |> :ets.match({:"$1", pid, :_})
    |> List.flatten()
  end

  @doc """
  Convenience: same as `Aiur.Events.Topic.matches?/2`. Exposed so
  callers don't have to import `Topic` separately.
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(pattern, topic), do: Topic.matches?(pattern, topic)

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :duplicate_bag,
        read_concurrency: true
      ])

    {:ok, %{table: table, monitors: %{}}}
  end

  @impl true
  def handle_call({:subscribe, pattern, pid}, _from, state) do
    ref = Process.monitor(pid)
    :ets.insert(@table, {pattern, pid, ref})
    {:reply, :ok, %{state | monitors: Map.put(state.monitors, ref, {pattern, pid})}}
  end

  def handle_call({:unsubscribe, pattern, pid}, _from, state) do
    state =
      case find_ref_for(pattern, pid) do
        nil ->
          state

        ref ->
          Process.demonitor(ref, [:flush])
          :ets.match_delete(@table, {pattern, pid, ref})
          %{state | monitors: Map.delete(state.monitors, ref)}
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Reap every binding for the dead subscriber. We use match_delete
    # against the pid alone so a single :DOWN cleans up all of that
    # subscriber's patterns at once.
    :ets.match_delete(@table, {:_, pid, :_})

    monitors =
      state.monitors
      |> Enum.reject(fn {_ref, {_pattern, monitored_pid}} -> monitored_pid == pid end)
      |> Map.new()

    {:noreply, %{state | monitors: Map.delete(monitors, ref)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp find_ref_for(pattern, pid) do
    case :ets.match_object(@table, {pattern, pid, :_}) do
      [{^pattern, ^pid, ref} | _] -> ref
      _ -> nil
    end
  end

  defp validate_pattern!("") do
    raise ArgumentError, "pattern must not be empty"
  end

  defp validate_pattern!(pattern) do
    cond do
      String.starts_with?(pattern, ".") ->
        raise ArgumentError, "pattern must not start with '.': #{inspect(pattern)}"

      String.ends_with?(pattern, ".") ->
        raise ArgumentError, "pattern must not end with '.': #{inspect(pattern)}"

      String.contains?(pattern, "..") ->
        raise ArgumentError, "pattern must not contain '..': #{inspect(pattern)}"

      true ->
        :ok
    end
  end
end
