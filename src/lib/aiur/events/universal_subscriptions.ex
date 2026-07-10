defmodule Aiur.Events.UniversalSubscriptions do
  @moduledoc false

  require Logger

  alias Aiur.Config
  alias Aiur.Events.SubscriptionStore

  @spec attach(String.t(), module()) :: :ok
  def attach(identifier, subscription_store \\ SubscriptionStore) when is_binary(identifier) do
    safe_attach(subscription_store, identifier)

    Enum.each(topics(identifier), fn {topic, reason} ->
      safe_add_subscription(subscription_store, identifier, topic, reason)
    end)

    :ok
  end

  @spec topics(String.t()) :: [{String.t(), String.t()}]
  def topics(identifier) when is_binary(identifier) do
    base_branch = base_branch_name()

    [
      {"system." <> base_branch <> ".branch.push", "base_branch:auto"},
      {"ticket." <> identifier <> ".issue.commented", "own_comments:auto"},
      {"ticket." <> identifier <> ".pr.review_comment", "own_comments:auto"},
      {"ticket." <> identifier <> ".ci.passed", "ci_status:auto"},
      {"ticket." <> identifier <> ".ci.failed", "ci_status:auto"},
      {"ticket." <> identifier <> ".operator.progress_request", "progress_checkin:auto"}
    ]
  end

  defp base_branch_name do
    case Config.settings!() do
      %{tracker: %{base_branch: name}} when is_binary(name) and name != "" -> name
      _ -> "main"
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
end
