defmodule Aiur.Events.UniversalSubscriptions do
  @moduledoc false

  require Logger

  alias Aiur.Config
  alias Aiur.Events.{IdGenerator, SubscriptionStore}

  @spec attach(String.t(), module()) :: :ok
  def attach(identifier, subscription_store \\ SubscriptionStore) when is_binary(identifier) do
    safe_attach(subscription_store, identifier)

    # Prune any `base_branch:auto` topic from a retired base before the
    # attach loop (re)adds the current one, so a base-branch change that
    # happened while this ticket was parked cannot leave it listening on the
    # old branch's push topic. See `reconcile_base_branch/2`.
    reconcile_base_branch(identifier, subscription_store)

    Enum.each(topics(identifier), fn {topic, reason} ->
      safe_add_subscription(subscription_store, identifier, topic, reason)
    end)

    :ok
  end

  @spec topics(String.t()) :: [{String.t(), String.t()}]
  def topics(identifier) when is_binary(identifier) do
    base_branch = Config.base_branch()

    [
      {"system." <> base_branch <> ".branch.push", "base_branch:auto"},
      {"system.config.base_branch.changed", "config_change:auto"},
      {"ticket." <> identifier <> ".issue.commented", "own_comments:auto"},
      {"ticket." <> identifier <> ".pr.review_comment", "own_comments:auto"},
      {"ticket." <> identifier <> ".ci.passed", "ci_status:auto"},
      {"ticket." <> identifier <> ".ci.failed", "ci_status:auto"},
      {"ticket." <> identifier <> ".operator.progress_request", "progress_checkin:auto"}
    ]
  end

  @doc """
  Reconciles a ticket's persisted `base_branch:auto` subscription against the
  current `tracker.base_branch`:

    * removes any `base_branch:auto` topic that no longer matches (a superseded
      `system.<old>.branch.push` whose base was retired);
    * adds the current `system.<base>.branch.push` topic if it is missing.

  Manual subscriptions on the same topics are never touched — removal is scoped
  by the `base_branch:auto` reason via `remove_subscription/3`. Safe to call
  repeatedly; returns the list of superseded topics that were pruned.
  """
  @spec reconcile_base_branch(String.t(), module()) :: [String.t()]
  def reconcile_base_branch(identifier, subscription_store \\ SubscriptionStore)
      when is_binary(identifier) do
    current = "system." <> Config.base_branch() <> ".branch.push"

    stale =
      case subscription_store.snapshot(identifier) do
        %{subscribed_to: subscribed_to} when is_list(subscribed_to) ->
          Enum.flat_map(subscribed_to, fn sub ->
            if Map.get(sub, "reason") == "base_branch:auto" and
                 Map.get(sub, "topic") != current do
              [Map.get(sub, "topic")]
            else
              []
            end
          end)

        _ ->
          []
      end

    Enum.each(stale, fn topic ->
      safe_remove_subscription(subscription_store, identifier, topic, "base_branch:auto")
    end)

    safe_add_subscription(subscription_store, identifier, current, "base_branch:auto")
    stale
  catch
    kind, reason ->
      Logger.warning("UniversalSubscriptions.reconcile_base_branch_failed identifier=#{identifier} reason=#{inspect({kind, reason})}")

      []
  end

  @doc """
  Pure reconcile transform for a `subscribed_to` list: drops every
  `base_branch:auto` entry whose topic is not the current base push topic and
  appends the current entry when absent. Used by `Aiur.Events.SubscriptionStore`
  to reconcile itself inline when it receives a `system.config.base_branch.changed`
  event (a running agent must stop listening on the retired branch's push topic
  without waiting for the next `attach`). Returns the new list.
  """
  @spec reconcile_subscribed_to([map()]) :: [map()]
  def reconcile_subscribed_to(subscribed_to) when is_list(subscribed_to) do
    current = "system." <> Config.base_branch() <> ".branch.push"

    kept =
      Enum.reject(subscribed_to, fn sub ->
        Map.get(sub, "reason") == "base_branch:auto" and Map.get(sub, "topic") != current
      end)

    if Enum.any?(kept, &(&1["topic"] == current)) do
      kept
    else
      kept ++
        [
          %{
            "topic" => current,
            "reason" => "base_branch:auto",
            "subscription_created_at_event_id" => IdGenerator.peek()
          }
        ]
    end
  end

  defp safe_attach(subscription_store, identifier) do
    subscription_store.attach(identifier)
  catch
    kind, reason ->
      Logger.warning("UniversalSubscriptions.attach_failed identifier=#{identifier} reason=#{inspect({kind, reason})}")
      :ok
  end

  defp safe_add_subscription(subscription_store, identifier, topic, reason) do
    subscription_store.add_subscription(identifier, topic, reason)
  catch
    kind, error ->
      Logger.warning("UniversalSubscriptions.add_subscription_failed identifier=#{identifier} topic=#{topic} reason=#{inspect({kind, error})}")
      :ok
  end

  defp safe_remove_subscription(subscription_store, identifier, topic, reason) do
    subscription_store.remove_subscription(identifier, topic, reason)
  catch
    kind, error ->
      Logger.warning("UniversalSubscriptions.remove_subscription_failed identifier=#{identifier} topic=#{topic} reason=#{inspect({kind, error})}")
      :ok
  end
end
