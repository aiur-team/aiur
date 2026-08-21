defmodule Aiur.Events.Publisher do
  @moduledoc """
  Shared publish boundary for every `Aiur.Events` source — GitHub
  firehose, ls-remote ticker, dependencies poll, and agent-emitted
  events all funnel through here so the policy choices (event IDs,
  contamination filter, replay dedup) live in one place rather than
  triplicated across source modules.

  ## Responsibilities

    1. **ID assignment** — every event gets an ID via
       `Aiur.Events.IdGenerator.next_id/0` at the moment of publish.
    2. **Contamination filter** — drops events whose issue number isn't
       in the orchestrator's tracked set (running/queued/recent) and
       drops events whose actor is the configured `daemon_account` (to
       prevent self-loops where Aiur reacts to its own writes).
    3. **Replay dedup** — sources that poll replay-prone APIs can pass
       a stable `:dedup_key` to avoid publishing the same PR/comment
       event repeatedly.
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
  alias Aiur.GitHub.ResourceStore
  alias Aiur.TicketObservation

  @table __MODULE__.Dedup
  # 1-hour dedup window. GitHub's Events API returns the same event
  # for hours, so a short window (originally 5 min) caused the same
  # `pr.opened` / `issue.commented` event to re-emit on every poll
  # cycle after the entry was swept. 1 hour comfortably covers
  # GitHub's polling-window re-emissions; the only cost is a few KB
  # of ETS state per dedupe key.
  @default_ttl_ms 3_600_000
  @sweep_interval_ms 60_000
  @durable_decision_names ["decision.requested", "decision.acknowledged", "decision.resolved"]

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
      bypasses filter (e.g. system topics like `system.<base_branch>.branch.push`)
    * `:actor` — author login; if matches `daemon_account`, drop
    * `:dedup_key` — stable source-specific key; if set, dedup is applied
    * `:resource` — an `Aiur.GitHub.ResourceStore` key naming the GitHub
      resource this event *is*, as `{type, owner, repo, id}`. Where
      `:dedup_key` suppresses a replay within this daemon's lifetime, this
      suppresses one across restarts and across pipes: a comment the webhook
      already published is not published again by the reconciliation sweep that
      re-reads it, because both name the same resource. Absent, or with no
      store running, publishing is exactly as it was before.
    * `:resource_version` — the resource's own mutation marker, normally the
      comment's `updated_at`. A GitHub comment is mutable and its id is stable
      across an edit, so identity alone cannot distinguish "already handled"
      from "changed since I handled it". Without this an edited comment would
      stay suppressed for the store's full retention window, and editing a
      comment to correct an agent is a normal workflow. Absent, suppression
      falls back to identity alone.
    * `:resource_source` — which pipe produced this event (`:webhook` or
      `:poll`), recorded alongside the resource. Defaults to `:poll`.
    * `:bypass_contamination` — when `true`, skip the tracked-issue
      filter for this publish. Used for external reactivation triggers
      (firehose `issue.commented` / `pr.review_comment`): a `:deactivated`
      ticket is intentionally absent from the tracked set (so the agent's
      own late `agent.*` emissions stay filtered), but an inbound human
      comment must still reach the orchestrator to reactivate it. The
      `bot_self_loop?` and dedup gates still apply, and the orchestrator
      and live agents self-gate by subscription, so untracked-issue
      comments published this way reach no reactivation target.
    * `:digest_source` — trusted internal provenance for the agent digest.
      Reserved payload keys are stripped before this option is applied, so
      external content cannot grant itself digest access.
  """
  @spec publish(String.t(), map(), keyword()) ::
          {:ok, pos_integer(), non_neg_integer()} | :filtered | :deduped | {:error, :decision_requires_durable_publish | :executor_namespace_rejects_github_source}
  def publish(topic, payload, opts \\ []) when is_binary(topic) and is_map(payload) do
    case rejection(topic, payload, opts) do
      nil -> do_publish(topic, payload, opts)
      rejection -> rejection
    end
  end

  # The gates, in the order they are cheapest to answer and most decisive.
  # `nil` means nothing rejected the event and it should be published.
  defp rejection(topic, payload, opts) do
    cond do
      durable_decision_topic?(topic) ->
        {:error, :decision_requires_durable_publish}

      executor_topic_from_github?(topic, payload, opts) ->
        {:error, :executor_namespace_rejects_github_source}

      filtered_bot_self_loop?(topic, Keyword.get(opts, :actor)) ->
        :filtered

      not Keyword.get(opts, :bypass_contamination, false) and
          not tracked?(Keyword.get(opts, :issue_number)) ->
        :filtered

      # Durable identity gate. The in-memory window below is the fast path but
      # it is ETS owned by this process: it empties on every daemon restart,
      # which is exactly when a duplicate is most likely, because a webhook
      # delivered the comment before the restart and the first sweep after it
      # reads the same comment back. Consulted first so a hit never pollutes
      # the volatile window with an entry that changes nothing.
      resource_processed?(opts) ->
        :deduped

      deduped?(Keyword.get(opts, :dedup_key)) ->
        :deduped

      true ->
        nil
    end
  end

  defp do_publish(topic, payload, opts) do
    id = IdGenerator.next_id()
    event = event_with_observation(topic, payload, id, opts)

    subscribers = Exchange.publish(topic, event)
    record_emit_marker(topic, event, opts)
    # Recorded *after* the publish, never before. A crash in between then
    # leaves the resource unmarked, so the next reconciliation sweep
    # republishes it — a duplicate the window above still absorbs. Marking
    # first would make the same crash suppress the event permanently,
    # because this store is the sweep's own source of suppression.
    mark_resource_processed(opts)
    DebugLog.broadcast(:publish, topic, id: id, body: payload)
    {:ok, id, subscribers}
  end

  defp resource_processed?(opts) do
    ResourceStore.processed?(Keyword.get(opts, :resource), Keyword.get(opts, :resource_version))
  end

  defp mark_resource_processed(opts) do
    ResourceStore.mark_processed(
      Keyword.get(opts, :resource),
      Keyword.get(opts, :resource_source, :poll),
      Keyword.get(opts, :resource_version)
    )
  end

  @doc """
  Publishes an event that is already durably persisted, under a
  caller-supplied `id` from `Aiur.Events.IdGenerator.reserve_durable_id/1`.
  Skips ID assignment and the contamination/dedup filters — the caller
  (`Aiur.DecisionStore`) already made the accept/reject decision
  durably; this is notification fan-out for something that already
  happened, not a new best-effort publish. Keeps the same Exchange
  fan-out, IssueLog marker, and debug broadcast behavior as `publish/3`.
  """
  @spec publish_persisted(String.t(), map(), pos_integer(), keyword()) ::
          {:ok, pos_integer(), non_neg_integer()} | {:error, :executor_namespace_rejects_github_source}
  def publish_persisted(topic, payload, id, opts \\ [])
      when is_binary(topic) and is_map(payload) and is_integer(id) do
    if executor_topic_from_github?(topic, payload, opts) do
      {:error, :executor_namespace_rejects_github_source}
    else
      event = event_with_observation(topic, payload, id, opts)

      subscribers = Exchange.publish(topic, event)
      record_emit_marker(topic, event, opts)
      DebugLog.broadcast(:publish, topic, id: id, body: payload)
      {:ok, id, subscribers}
    end
  end

  defp executor_topic_from_github?("executor." <> _rest, payload, opts) do
    source = Keyword.get(opts, :source) || Keyword.get(opts, :observation_source) || Map.get(payload, :source) || Map.get(payload, "source")
    source in [:github, "github"] or match?(%{kind: :github}, source) or match?(%{"kind" => "github"}, source)
  end

  defp executor_topic_from_github?(_topic, _payload, _opts), do: false

  # Reserved Decision lifecycle names must only ever reach Exchange through
  # `Aiur.DecisionStore`'s persist-before-notify path (via
  # `publish_persisted/4`) — direct `publish/3` calls bypass durability
  # entirely, so every call site is rejected here regardless of the
  # ticket-namespace prefix a caller builds the topic with.
  defp durable_decision_topic?(topic) do
    Enum.any?(@durable_decision_names, &(topic == &1 or String.ends_with?(topic, ".#{&1}")))
  end

  # Compatibility boundary: every event gains an envelope, but legacy callers
  # remain explicitly unattributed. Identity is accepted only through a trusted
  # producer option; topic, issue number, and payload are never identity input.
  defp ticket_observation(payload, id, opts) do
    opts
    |> observation_options(id)
    |> then(&TicketObservation.normalize(payload, &1))
  end

  defp event_with_observation(topic, payload, id, opts) do
    payload
    |> Map.drop([:ticket_observation, "ticket_observation", :digest_source, "digest_source"])
    |> Map.merge(%{id: id, topic: topic})
    |> maybe_put_digest_source(Keyword.get(opts, :digest_source))
    |> Map.put(:ticket_observation, ticket_observation(payload, id, opts))
  end

  defp maybe_put_digest_source(event, source) when source in [:agent, :orchestrator, :system],
    do: Map.put(event, :digest_source, source)

  defp maybe_put_digest_source(event, _source), do: event

  defp observation_options(opts, id) do
    [event_id: id, observed_at: observation_time(opts)]
    |> copy_option(opts, :identity, :identity)
    |> copy_option(opts, :observation_source, :source)
    |> copy_option(opts, :observation_provenance, :provenance)
    |> copy_option(opts, :occurred_at, :occurred_at)
    |> copy_option(opts, :payload_version, :payload_version)
  end

  defp observation_time(opts) do
    case Keyword.get(opts, :observation_clock, &DateTime.utc_now/0) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> nil
    end
  rescue
    _error -> nil
  end

  defp copy_option(accumulator, opts, source_key, destination_key) do
    if Keyword.has_key?(opts, source_key) do
      Keyword.put(accumulator, destination_key, Keyword.fetch!(opts, source_key))
    else
      accumulator
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
    # The daemon identity, not the agent one: this drops events the daemon
    # itself produced. An agent's write is a real external event the daemon
    # must react to, so it deliberately does not match here.
    case GitHubConfig.daemon_account() do
      bot when is_binary(bot) -> String.downcase(actor) == String.downcase(bot)
      _ -> false
    end
  end

  defp authoritative_merge_topic?(topic), do: String.ends_with?(topic, ".pr.merged")

  defp filtered_bot_self_loop?(topic, actor),
    do: bot_self_loop?(actor) and not authoritative_merge_topic?(topic)

  defp tracked?(nil), do: true

  defp tracked?(issue_number) do
    case :persistent_term.get({__MODULE__, :tracked_fn}, nil) do
      nil -> true
      fun when is_function(fun, 1) -> fun.(issue_number)
    end
  end

  defp deduped?(nil), do: false

  defp deduped?({repo, kind, id} = key) when is_binary(repo) and is_binary(kind) and is_binary(id) do
    if seen?(key) do
      true
    else
      record_seen(key)
      false
    end
  end

  # Catch-all: a partially-populated dedup_key MUST NOT crash the
  # publish path. Drop the dedup signal and let the event through.
  defp deduped?(_other), do: false

  defp record_seen(key) do
    :ets.insert(@table, {key, System.monotonic_time(:millisecond)})
    :ok
  end

  defp seen?(key) do
    case :ets.lookup(@table, key) do
      [{_, recorded_at}] ->
        System.monotonic_time(:millisecond) - recorded_at < ttl_ms()

      [] ->
        false
    end
  end

  defp ttl_ms do
    :persistent_term.get({__MODULE__, :ttl_ms}, @default_ttl_ms)
  end
end
