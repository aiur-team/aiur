defmodule Aiur.Orchestrator.AutoSubscriptions do
  @moduledoc """
  Manages automatic blocker and blockee event subscriptions.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator.{IssueSync, State}

  # Asymmetric auto-subscribe: when the orchestrator's poll observes a new blocker on
  # `issue.blocked_by`, asymmetrically auto-subscribe both sides:
  # - blockee subscribes to the actionable subset of the blocker's events
  # - blocker subscribes to blockee's block-state events only
  # See origin: docs/brainstorms/2026-05-24-aiur-event-publishing-
  # subscriptions-requirements.md (Subscriptions section). Idempotent via
  # SubscriptionStore.add_subscription's existing duplicate short-circuit.

  @spec auto_subscribe_for_dependency(term(), term()) :: :ok | {:error, term()}
  def auto_subscribe_for_dependency(blockee, blocker) when is_map(blocker) do
    with blockee_identifier when is_binary(blockee_identifier) <- blockee_identifier_for(blockee),
         blocker_identifier when is_binary(blocker_identifier) <- blocker_identifier_for(blocker),
         :ok <-
           attach_and_subscribe(
             blockee_identifier,
             default_blockee_subscriptions(blocker_identifier),
             "blocker:auto"
           ),
         :ok <-
           attach_and_subscribe(
             blocker_identifier,
             default_blocker_subscriptions(blockee_identifier),
             "blockee:auto"
           ) do
      :ok
    else
      nil -> :ok
      {:error, _} = err -> err
    end
  end

  def auto_subscribe_for_dependency(_blockee, _blocker), do: :ok

  @doc """
  Attach the standard blocker→blockee subscription pair WITHOUT
  going through GitHub poll detection. Called from
  `Aiur.AgentRunner.declare_blocker_for_issue/2` so the subscription
  goes in the SubscriptionStore at declare-time, not on the next
  reconcile tick after GitHub eventually surfaces the dependency.

  This matters because:
    * `IssueDependencies.declare/2` posts to GitHub's `/issues/.../dependencies`
      API and may return `:already_present` for a stale dependency
      that GitHub later mutates away (PR close + open cycle has been
      observed to drop the dependency).
    * Without the direct subscribe, the blockee's SubscriptionStore never
      receives `ticket.<blocker>.agent.unblocked`, so the orchestrator's
      `subscribed_to_topic?/2` check returns false and the blockee never
      auto-resumes. The paired branch-push subscription still carries the ref
      used after the explicit readiness signal.

  Idempotent: SubscriptionStore.add_subscription short-circuits on
  duplicate `(identifier, topic)`.
  """
  @spec subscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) ::
          :ok | {:error, term()}
  def subscribe_for_declared_blocker(blockee_identifier, blocker_identifier) do
    blockee_str = to_string(blockee_identifier)
    blocker_str = to_string(blocker_identifier)

    with :ok <-
           attach_and_subscribe(
             blockee_str,
             default_blockee_subscriptions(blocker_str),
             "blocker:auto"
           ),
         :ok <-
           attach_and_subscribe(
             blocker_str,
             default_blocker_subscriptions(blockee_str),
             "blockee:auto"
           ) do
      :ok
    else
      {:error, _} = err ->
        Logger.warning("subscribe_for_declared_blocker(#{blockee_str}, #{blocker_str}) failed: #{inspect(err)}")

        err
    end
  end

  @spec auto_unsubscribe_for_dependency(term(), term()) :: :ok | {:error, term()}
  def auto_unsubscribe_for_dependency(blockee, blocker) when is_map(blocker) do
    with blockee_identifier when is_binary(blockee_identifier) <- blockee_identifier_for(blockee),
         blocker_identifier when is_binary(blocker_identifier) <- blocker_identifier_for(blocker),
         :ok <-
           remove_auto_subscriptions(
             blockee_identifier,
             default_blockee_subscriptions(blocker_identifier),
             "blocker:auto"
           ),
         :ok <-
           remove_auto_subscriptions(
             blocker_identifier,
             default_blocker_subscriptions(blockee_identifier),
             "blockee:auto"
           ) do
      :ok
    else
      nil -> :ok
      {:error, _} = err -> err
    end
  end

  def auto_unsubscribe_for_dependency(_blockee, _blocker), do: :ok

  @spec unsubscribe_for_declared_blocker(String.t() | integer(), String.t() | integer()) :: :ok
  def unsubscribe_for_declared_blocker(blockee_identifier, blocker_identifier) do
    blockee = %Issue{identifier: to_string(blockee_identifier)}
    blocker = %{identifier: to_string(blocker_identifier)}
    auto_unsubscribe_for_dependency(blockee, blocker)
  end

  @doc false
  # Allows tests to inject a failing add_subscription without killing the
  # real GenServer — same pattern as SubscriptionStore.set_enqueue_fn/1.
  @spec set_add_subscription_fn((String.t(), String.t(), String.t() -> :ok | {:error, term()}) | nil) :: :ok
  def set_add_subscription_fn(fun) when is_function(fun, 3) or is_nil(fun) do
    :persistent_term.put({__MODULE__, :add_subscription_fn}, fun)
  end

  @doc false
  @spec set_remove_subscription_fn((String.t(), String.t(), String.t() -> :ok | {:error, term()}) | nil) :: :ok
  def set_remove_subscription_fn(fun) when is_function(fun, 3) or is_nil(fun) do
    :persistent_term.put({__MODULE__, :remove_subscription_fn}, fun)
  end

  defp add_subscription_fn do
    :persistent_term.get({__MODULE__, :add_subscription_fn}, nil) ||
      (&SubscriptionStore.add_subscription/3)
  end

  defp remove_subscription_fn do
    :persistent_term.get({__MODULE__, :remove_subscription_fn}, nil) ||
      (&SubscriptionStore.remove_subscription/3)
  end

  defp attach_and_subscribe(identifier, topics, reason) do
    with :ok <- SubscriptionStore.attach(identifier) do
      add_fn = add_subscription_fn()

      Enum.reduce_while(topics, :ok, fn topic, :ok ->
        try do
          case add_fn.(identifier, topic, reason) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, {:error, {:add_subscription_failed, topic, err}}}
          end
        catch
          :exit, exit_reason ->
            {:halt, {:error, {:add_subscription_failed, topic, exit_reason}}}
        end
      end)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp remove_auto_subscriptions(identifier, topics, expected_reason) do
    remove_fn = remove_subscription_fn()

    Enum.reduce_while(topics, :ok, fn topic, :ok ->
      try do
        case remove_fn.(identifier, topic, expected_reason) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, {:error, {:remove_subscription_failed, topic, err}}}
        end
      catch
        :exit, exit_reason ->
          {:halt, {:error, {:remove_subscription_failed, topic, exit_reason}}}
      end
    end)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp default_blockee_subscriptions(blocker_identifier) when is_binary(blocker_identifier) do
    base = "ticket." <> blocker_identifier

    # Topic strings must match the publisher source modules literally
    # (Exchange routes by literal segment match):
    #   LsRemoteTicker        -> ticket.<N>.branch.push
    #   GithubCommentsPoller  -> ticket.<N>.issue.commented / pr.review_comment
    #   GithubFirehose        -> ticket.<N>.pr.{opened,merged,closed,…}
    [
      base <> ".branch.push",
      base <> ".branch.force-push",
      base <> ".pr.opened",
      base <> ".pr.merged",
      base <> ".agent.decision.*",
      base <> ".agent.blocked",
      base <> ".agent.unblocked",
      base <> ".agent.attention.*",
      base <> ".issue.commented"
    ]
  end

  defp default_blocker_subscriptions(blockee_identifier) when is_binary(blockee_identifier) do
    base = "ticket." <> blockee_identifier

    [
      base <> ".agent.blocked",
      base <> ".agent.unblocked"
    ]
  end

  defp blockee_identifier_for(%Issue{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp blockee_identifier_for(_), do: nil

  defp blocker_identifier_for(%{identifier: identifier}) when is_binary(identifier),
    do: identifier

  defp blocker_identifier_for(%{"identifier" => identifier}) when is_binary(identifier),
    do: identifier

  defp blocker_identifier_for(_), do: nil

  # Mid-turn-drain helpers. Returns the list of direct-blocker
  # identifiers for the running ticket (small — typically 0-3).
  # Kept as a list rather than a MapSet so the consumer doesn't have
  # to navigate dialyzer's opaque-type complaints on MapSet.member?.
  #
  # Two sources, unioned, because neither alone is complete.
  #
  # The polled issue is authoritative on Linear, whose poll decodes blockers
  # inline. It is empty on GitHub for every ticket: the list poll never
  # populates `blocked_by` (`Aiur.GitHub.Issues.hydrate_blocked_by/2` exists
  # precisely because of that), and the two places that do hydrate — the
  # dispatch gate and the cleared-dependency resume — keep the hydrated copy
  # locally and never write it back into `last_polled_issues`. So on GitHub
  # this returned `[]` for every ticket, which made `blocker_critical_digest?`
  # unconditionally false and left the whole mid-turn blocker drain inert —
  # every blocker readiness signal waited for a turn boundary a parked agent
  # never reaches (#2556).
  #
  # The subscription bindings close that gap without a dependency read. They
  # are written at declare time by `subscribe_for_declared_blocker/2` and by
  # the poll's `auto_subscribe_for_dependency/2`, carry the `blocker:auto`
  # reason on exactly the blockee's side of the edge, and are removed with the
  # edge — so they name the same blockers on either tracker and stay bounded by
  # the declared dependencies rather than by binding count. Reason-scoping is
  # load-bearing: it excludes `blockee:auto` (the reverse edge, stored on the
  # blocker) and `manual:agent` (a sibling an agent chose to watch), neither of
  # which may interrupt a live turn.
  #
  # Fail-safe: the snapshot is a call into a per-ticket GenServer, and a
  # missing, restarting, or timing-out store yields no blockers rather than an
  # exception. The polled set still stands, so the worst case is exactly the
  # behaviour before this union.
  @spec direct_blockers_for(State.t(), String.t()) :: [String.t()]
  def direct_blockers_for(%State{} = state, identifier) when is_binary(identifier) do
    (polled_direct_blockers(state, identifier) ++ subscribed_direct_blockers(identifier))
    |> Enum.uniq()
  end

  def direct_blockers_for(_state, _identifier), do: []

  defp polled_direct_blockers(%State{last_polled_issues: polled}, identifier)
       when is_map(polled) do
    case Enum.find(polled, fn {_id, %Issue{identifier: i}} -> i == identifier end) do
      {_id, %Issue{} = issue} ->
        issue
        |> IssueSync.blocker_map()
        |> Map.values()
        |> Enum.map(&blocker_identifier_for/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp polled_direct_blockers(_state, _identifier), do: []

  defp subscribed_direct_blockers(identifier) do
    case SubscriptionStore.snapshot(identifier) do
      %{subscribed_to: subscriptions} when is_list(subscriptions) ->
        subscriptions
        |> Enum.filter(&(subscription_reason(&1) == "blocker:auto"))
        |> Enum.map(&(&1 |> subscription_topic() |> blocker_identifier_from_topic()))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _no_store ->
        []
    end
  catch
    :exit, reason ->
      Logger.warning("direct_blockers_for subscription snapshot failed: identifier=#{identifier} reason=#{inspect(reason)}")

      []
  end

  # Bindings are string-keyed on disk and read back that way, but the same
  # shape is built with atom keys in places, so both are accepted — as
  # `Aiur.Orchestrator.PushRouting.subscribed_to_topic?/2` already does.
  defp subscription_reason(%{"reason" => reason}), do: reason
  defp subscription_reason(%{reason: reason}), do: reason
  defp subscription_reason(_subscription), do: nil

  defp subscription_topic(%{"topic" => topic}), do: topic
  defp subscription_topic(%{topic: topic}), do: topic
  defp subscription_topic(_subscription), do: nil

  defp blocker_identifier_from_topic(topic) when is_binary(topic) do
    case String.split(topic, ".") do
      ["ticket", blocker_identifier | _rest] -> blocker_identifier
      _ -> nil
    end
  end

  defp blocker_identifier_from_topic(_topic), do: nil

  @spec blocker_critical_digest?(term(), [String.t()]) :: boolean()
  def blocker_critical_digest?(
        %{category: :coordination_event, event_type: :events_digest, body: body},
        direct_blockers
      ) do
    events = Map.get(body || %{}, :events, [])
    Enum.any?(events, fn event -> blocker_critical_event?(event, direct_blockers) end)
  end

  def blocker_critical_digest?(_item, _direct_blockers), do: false

  defp blocker_critical_event?(event, direct_blockers) when is_map(event) do
    topic = Map.get(event, :topic) || Map.get(event, "topic")

    cond do
      not is_binary(topic) -> false
      Enum.empty?(direct_blockers) -> false
      true -> blocker_critical_topic?(topic, direct_blockers)
    end
  end

  defp blocker_critical_event?(_event, _direct_blockers), do: false

  # `pr.merged` is a readiness signal exactly like `agent.unblocked`, and it is
  # the ONLY one on the path where the Executor merges the blocker's pull
  # request rather than the blocker's own agent announcing its release. Merging
  # advances the base branch, so it raises `system.<base>.branch.push` and never
  # `ticket.<blocker>.branch.push` — leaving that Executor-driven path with no
  # drain-eligible topic at all. A blockee waiting inside a live turn then held
  # its subscription, received the digest, and was never interrupted with it:
  # the wake sat pending until a turn boundary the agent never reached, and only
  # an operator relaying the news in prose released it (#2556).
  #
  # Fan-out stays bounded by `direct_blockers`, not by binding count: a ticket
  # with many bindings across three blockers can be woken at most once per
  # blocker merge, and the merge itself is deduped at the publisher.
  defp blocker_critical_topic?(topic, direct_blockers) do
    case String.split(topic, ".") do
      ["ticket", id, "branch", "push"] -> id in direct_blockers
      ["ticket", id, "branch", "force-push"] -> id in direct_blockers
      ["ticket", id, "pr", "merged"] -> id in direct_blockers
      ["ticket", id, "agent", "unblocked"] -> id in direct_blockers
      ["ticket", id, "agent", "decision", _slug] -> id in direct_blockers
      _ -> false
    end
  end
end
