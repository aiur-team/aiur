defmodule Aiur.GitHub.CacheInspector.Events do
  @moduledoc """
  The store-change subscription the debug page rides on.

  U2 publishes an event per resource write; U9 subscribes so a webhook delivery
  or an agent mutation is *visible* arriving. The two units are being built at
  the same time, so this module is the seam between them rather than a second
  implementation of either: it owns the topic name and normalises whatever
  arrives into the one shape the page consumes.

  ## Why it accepts more than one shape

  The publisher does not exist yet on this branch. Guessing its exact tuple and
  hard-matching it would give a page that silently stops updating if the guess
  is off by a field — the worst possible failure here, because "no events" and
  "nothing changed" look identical on screen, and the page's whole purpose is
  proving deliveries land.

  So `normalize/1` accepts the documented shape and the plausible variants
  around it, and answers `:ignore` for anything it cannot read. When U2 lands,
  the extra clauses become dead and can be deleted in that PR; until then the
  page works against whichever shape ships.

  The contract this page needs, and the one U2 should publish:

      Phoenix.PubSub.broadcast(
        Aiur.PubSub,
        "github-resource-store:changed",
        {:github_resource_written, %{key: {type, owner, repo, id}, source: :webhook, version: "..."}}
      )
  """

  @pubsub Aiur.PubSub
  @topic "github-resource-store:changed"

  @doc "The topic U2 publishes on and this page listens to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the caller to store changes.

  Never raises. A dashboard page that cannot subscribe must still render the
  cache it can already see; losing liveness is a degraded page, losing the page
  is an outage.
  """
  @spec subscribe(module()) :: :ok
  def subscribe(pubsub \\ @pubsub) do
    case Process.whereis(pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.subscribe(pubsub, @topic)
      _not_running -> :ok
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Broadcasts a store change. Provided so tests and U2 share one publisher.
  """
  @spec broadcast(map(), module()) :: :ok
  def broadcast(change, pubsub \\ @pubsub) when is_map(change) do
    case Process.whereis(pubsub) do
      pid when is_pid(pid) -> Phoenix.PubSub.broadcast(pubsub, @topic, {:github_resource_written, change})
      _not_running -> :ok
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Turns an inbound message into `{:ok, identity}` or `:ignore`.

  `identity` is the same string the page uses for a deep link, so a change event
  can highlight the row it belongs to without another read of the store.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :ignore
  def normalize({:github_resource_written, %{key: key}}), do: from_key(key)
  def normalize({:github_resource_written, {_type, _owner, _repo, _id} = key}), do: from_key(key)
  def normalize({:github_resource_changed, %{key: key}}), do: from_key(key)
  def normalize({:github_resource_store_changed, %{key: key}}), do: from_key(key)
  def normalize({:resource_store_written, %{key: key}}), do: from_key(key)
  def normalize(_message), do: :ignore

  defp from_key({type, owner, repo, id}) do
    {:ok, Aiur.GitHub.CacheInspector.Entry.identity(type, to_string(owner), to_string(repo), to_string(id))}
  end

  defp from_key(_key), do: :ignore
end
