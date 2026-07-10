defmodule Aiur.AgentRunner.BootstrapDigest do
  @moduledoc """
  Enqueues the first-turn bootstrap digest of missed events.

  Reads from each publisher log the subscriber is subscribed to (keyed by the
  `ticket.<N>.…` prefix), merges with current comment context, dedupes, and
  enqueues a single batched event-digest queue item so an agent waking from a
  long offline window does not serialize hundreds of orchestrator calls.
  """

  require Logger

  alias Aiur.AgentRunner.{CommentContext, EventsDigest}
  alias Aiur.Events.{SubscriptionStore, Topic, UniversalSubscriptions}
  alias Aiur.{Issue, IssueLog}

  @doc false
  @spec maybe_enqueue_bootstrap_digest(Issue.t() | term()) :: :ok
  def maybe_enqueue_bootstrap_digest(%Issue{identifier: identifier} = issue) when is_binary(identifier) do
    snapshot = SubscriptionStore.snapshot(identifier)

    replay_events =
      case snapshot do
        %{last_seen_event_id: cursor, subscribed_to: subs} when is_integer(cursor) and subs != [] ->
          bootstrap_events(cursor, subs)

        _ ->
          []
      end

    comment_events = CommentContext.events(issue)

    events =
      (replay_events ++ comment_events)
      |> Enum.uniq_by(&bootstrap_event_key/1)
      |> Enum.sort_by(&EventsDigest.event_field(&1, :id))

    enqueue_bootstrap_if_any(identifier, events, bootstrap_cursor_for_log(snapshot))
  end

  def maybe_enqueue_bootstrap_digest(_issue), do: :ok

  # At runner start, every agent auto-subscribes to:
  # - `system.<base>.branch.push` so it sees base-branch movement
  # - `ticket.<self>.issue.commented` so another agent's comment
  #   on its issue reaches it
  # - `ticket.<self>.pr.review_comment` so review comments on its PR
  #   reach it
  # `add_subscription/3` short-circuits on duplicate so this is idempotent
  # across restarts. Reasons: `base_branch:auto`, `own_comments:auto`.
  @doc false
  @spec maybe_attach_universal_subscriptions(Issue.t() | term()) :: :ok
  def maybe_attach_universal_subscriptions(%Issue{identifier: identifier}) when is_binary(identifier) do
    UniversalSubscriptions.attach(identifier)
  end

  def maybe_attach_universal_subscriptions(_issue), do: :ok

  @doc false
  @spec bootstrap_event_key(map() | term()) :: {term(), term()} | term()
  def bootstrap_event_key(event) when is_map(event) do
    topic = EventsDigest.event_field(event, :topic)
    comment_id = event |> EventsDigest.event_field(:comment) |> comment_event_id_or_nil()
    {topic, comment_id || EventsDigest.event_field(event, :id)}
  end

  def bootstrap_event_key(event), do: event

  # Deliver a bootstrap digest of missed events on the first turn
  # after agent (re)start. The subscriber's cursor lives in its own
  # SubscriptionStore; the events themselves are persisted to the
  # PUBLISHER's per-issue log via `Aiur.Events.Publisher.record_emit_marker/3`
  # (which uses the ticket-id from the topic, not the subscriber's id).
  # Bootstrap therefore must read from each publisher log the
  # subscriber subscribes to, not from the subscriber's own log.
  #
  # Each subscription pattern's `ticket.<N>.…` prefix tells us which
  # publisher log to read. Patterns under `system.…` aren't backed by
  # an issue log today; they're listed in the residual risks (operator-
  # facing system events can't be replayed on restart yet).
  defp bootstrap_events(cursor, subscribed_to) do
    patterns = subscribed_to |> Enum.map(&Map.get(&1, "topic")) |> Enum.reject(&is_nil/1)
    publisher_ids = publisher_ids_for_patterns(patterns)

    publisher_ids
    |> Enum.flat_map(fn publisher_id ->
      IssueLog.event_history(publisher_id, since_id: cursor)
    end)
    |> Enum.filter(fn ev -> matches_any_pattern?(ev.topic, patterns) end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp comment_event_id_or_nil(%{} = comment) do
    case Map.get(comment, "id") || Map.get(comment, :id) do
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp comment_event_id_or_nil(_comment), do: nil

  defp bootstrap_cursor_for_log(%{last_seen_event_id: cursor}) when is_integer(cursor), do: cursor
  defp bootstrap_cursor_for_log(_snapshot), do: nil

  # Extract the static `<id>` from `ticket.<id>.…` patterns so bootstrap
  # reads the publisher's log, not the subscriber's. Returns the set of
  # IDs whose logs we need to consult. Wildcard segments (`*`, `#`) in
  # the id position widen the read to all known issue logs (rare in
  # practice — the default subset uses concrete ids). `system.…`
  # patterns have no per-issue log and are skipped here; system-event
  # replay on restart is a known gap.
  defp publisher_ids_for_patterns(patterns) do
    patterns
    |> Enum.flat_map(&publisher_ids_for_pattern/1)
    |> Enum.uniq()
  end

  defp publisher_ids_for_pattern(pattern) when is_binary(pattern) do
    case String.split(pattern, ".") do
      ["ticket", id | _] when id not in ["*", "#"] -> [id]
      _ -> []
    end
  end

  defp publisher_ids_for_pattern(_), do: []

  defp matches_any_pattern?(_topic, []), do: false

  defp matches_any_pattern?(topic, patterns) when is_binary(topic) do
    Enum.any?(patterns, fn pattern ->
      is_binary(pattern) and Topic.matches?(pattern, topic)
    end)
  end

  defp matches_any_pattern?(_topic, _patterns), do: false

  defp enqueue_bootstrap_if_any(_identifier, [], _cursor), do: :ok

  defp enqueue_bootstrap_if_any(identifier, events, cursor) do
    Logger.info("aiur_bootstrap_digest identifier=#{identifier} since_id=#{cursor} count=#{length(events)}")

    # One batched GenServer.call carries every missed event in one
    # queue item, so an agent waking from a long offline window with
    # hundreds of missed events doesn't serialize that many calls
    # through the orchestrator mailbox.
    case enqueue_bootstrap_batch(identifier, events) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("aiur_bootstrap_digest enqueue_failed identifier=#{identifier} reason=#{inspect(reason)}")

        :ok
    end
  end

  defp enqueue_bootstrap_batch(identifier, events) do
    GenServer.call(Aiur.Orchestrator, {:enqueue_event_digest_batch, identifier, events}, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end
end
