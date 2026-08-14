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
  @spec direct_blockers_for(State.t(), String.t()) :: [String.t()]
  def direct_blockers_for(%State{last_polled_issues: polled}, identifier)
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

  def direct_blockers_for(_state, _identifier), do: []

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

  defp blocker_critical_topic?(topic, direct_blockers) do
    case String.split(topic, ".") do
      ["ticket", id, "branch", "push"] -> id in direct_blockers
      ["ticket", id, "branch", "force-push"] -> id in direct_blockers
      ["ticket", id, "agent", "unblocked"] -> id in direct_blockers
      ["ticket", id, "agent", "decision", _slug] -> id in direct_blockers
      _ -> false
    end
  end
end
