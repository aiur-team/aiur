defmodule Aiur.Events.Publisher do
  @moduledoc """
  Shared publish boundary for every `Aiur.Events` source — GitHub
  firehose, ls-remote ticker, dependencies poll, and agent-emitted
  events all funnel through here so the policy choices (event IDs,
  contamination filter, push dedup) live in one place rather than
  triplicated across source modules.

  ## Responsibilities

    1. **ID assignment** — every event gets an ID via
       `Aiur.Events.IdGenerator.next_id/0` at the moment of publish.
    2. **Contamination filter** — drops events whose issue number isn't
       in the orchestrator's tracked set (running/queued/recent) and
       drops events whose actor is the configured `bot_account` (to
       prevent self-loops where Aiur reacts to its own writes).
    3. **`(repo, ref, sha)` push dedup** — when firehose and ls-remote
       both observe the same push, only the first emits the event.
       Dedup window defaults to 5 minutes (covers normal arrival skew).
    4. **Exchange.publish/2 fan-out** — once filters pass, hands off
       to the Exchange which sends to every matching subscriber.

  ## Why a GenServer

  Owns the dedup ETS table so it can run a TTL sweep timer. Mutations
  go through the GenServer; reads are direct ETS lookups.

  ## Tracked-set lookup

  `tracked?/1` is injected via `:tracked_fn` opt so the orchestrator
  can pass the live running/queued/recent issue numbers without
  Publisher having to call back into orchestrator state (avoiding a
  GenServer call loop). Default is `fn _ -> true end` — useful in
  tests where the contamination filter is not the focus.
  """

  use GenServer

  require Logger

  alias Aiur.Events.{DebugLog, Exchange, IdGenerator}
  alias Aiur.GitHub.Config, as: GitHubConfig

  @table __MODULE__.Dedup
  @default_ttl_ms 300_000
  @sweep_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Publishes `payload` on `topic` after running contamination filter +
  push-dedup. Returns:

    * `{:ok, id, subscribers}` — published; `id` is the assigned event
      ID, `subscribers` is the count from `Exchange.publish/2`.
    * `:filtered` — dropped by contamination filter (untracked issue or
      bot self-loop).
    * `:deduped` — dropped because the `(repo, ref, sha)` triple is in
      the dedup window.

  Options:

    * `:issue_number` — number used by the contamination filter; nil
      bypasses filter (e.g. system topics like `system.main.branch.push`)
    * `:actor` — author login; if matches `bot_account`, drop
    * `:dedup_key` — `{repo, ref, sha}` triple; if set, dedup is applied
  """
  @spec publish(String.t(), map(), keyword()) ::
          {:ok, pos_integer(), non_neg_integer()} | :filtered | :deduped
  def publish(topic, payload, opts \\ []) when is_binary(topic) and is_map(payload) do
    actor = Keyword.get(opts, :actor)

    cond do
      bot_self_loop?(actor) ->
        :filtered

      not tracked?(Keyword.get(opts, :issue_number)) ->
        :filtered

      deduped?(Keyword.get(opts, :dedup_key)) ->
        :deduped

      true ->
        id = IdGenerator.next_id()
        event = Map.merge(payload, %{id: id, topic: topic})
        subscribers = Exchange.publish(topic, event)
        record_emit_marker(topic, event, opts)
        DebugLog.broadcast(:publish, topic, id: id)
        {:ok, id, subscribers}
    end
  end

  defp record_emit_marker(topic, event, opts) do
    # IssueLog markers — `:emit` for any publish, `:self` when the topic
    # is the agent's own (ticket.<id>.agent.*). The IssueLog identifier
    # is the ticket id (string) extracted from the topic for the common
    # `ticket.<id>.*` shape; system.* topics are repo-wide and don't
    # belong to a single per-issue log.
    case extract_ticket_id(topic) do
      nil ->
        :ok

      ticket_id ->
        kind =
          cond do
            opts[:self_emit] == true -> :self
            String.starts_with?(topic, "ticket.#{ticket_id}.agent.") -> :self
            true -> :emit
          end

        Aiur.IssueLog.record_event(ticket_id, kind, event)
    end
  end

  defp extract_ticket_id("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [id, _] -> id
      _ -> nil
    end
  end

  defp extract_ticket_id(_), do: nil

  @doc """
  Marks `(repo, ref, sha)` as seen. Called by the source module that
  successfully published the push event so the other source skips it.
  """
  @spec record_push(String.t(), String.t(), String.t()) :: :ok
  def record_push(repo, ref, sha) do
    :ets.insert(@table, {{repo, ref, sha}, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Returns true if `(repo, ref, sha)` was recorded within the dedup
  window. Public so source modules can pre-check before formatting an
  event payload (saves work on the dedup-loser side).
  """
  @spec push_seen?(String.t(), String.t(), String.t()) :: boolean()
  def push_seen?(repo, ref, sha) do
    case :ets.lookup(@table, {repo, ref, sha}) do
      [{_, recorded_at}] ->
        System.monotonic_time(:millisecond) - recorded_at < ttl_ms()

      [] ->
        false
    end
  end

  @doc """
  Replaces the function used by `tracked?/1` to consult the running
  issue set. Orchestrator wires this up on startup. Stored in
  `:persistent_term` so `publish/3` (the hot path) reads it without a
  GenServer call.
  """
  @spec set_tracked_fn((String.t() | integer() | nil -> boolean())) :: :ok
  def set_tracked_fn(fun) when is_function(fun, 1) do
    :persistent_term.put({__MODULE__, :tracked_fn}, fun)
  end

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval_ms)

    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    :persistent_term.put({__MODULE__, :ttl_ms}, ttl)

    case Keyword.get(opts, :tracked_fn) do
      nil -> :ok
      fun when is_function(fun, 1) -> set_tracked_fn(fun)
    end

    {:ok, %{table: table, ttl_ms: ttl}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - state.ttl_ms
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp bot_self_loop?(nil), do: false

  defp bot_self_loop?(actor) when is_binary(actor) do
    case GitHubConfig.bot_account() do
      bot when is_binary(bot) -> String.downcase(actor) == String.downcase(bot)
      _ -> false
    end
  end

  defp tracked?(nil), do: true

  defp tracked?(issue_number) do
    case :persistent_term.get({__MODULE__, :tracked_fn}, nil) do
      nil -> true
      fun when is_function(fun, 1) -> fun.(issue_number)
    end
  end

  defp deduped?(nil), do: false

  defp deduped?({repo, ref, sha}) when is_binary(repo) and is_binary(ref) and is_binary(sha) do
    if push_seen?(repo, ref, sha) do
      true
    else
      record_push(repo, ref, sha)
      false
    end
  end

  defp ttl_ms do
    :persistent_term.get({__MODULE__, :ttl_ms}, @default_ttl_ms)
  end
end
