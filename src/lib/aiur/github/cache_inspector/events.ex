defmodule Aiur.GitHub.CacheInspector.Events do
  @moduledoc """
  The store-change subscription the debug page rides on.

  `Aiur.GitHub.ResourceStore` publishes one `{:github_resource_changed, change}`
  per write that a subscriber could observe, so the page learns that a webhook
  delivery or an agent mutation landed without asking GitHub anything. This
  module is the thin seam between that publisher and the page: it owns the
  subscription and turns a change into the identity string the page already uses
  for rows and deep links.

  ## The body is deliberately not in the message

  `change` carries identity, `:source`, `:version`, `:data_version`, `:etag`,
  `:data?` and `:recorded_at_ms` — never the cached body. Copying a bounded but
  not small body to every subscriber would make fan-out cost scale with the
  number of people looking, which is the thing this whole design removes. A
  subscriber therefore re-reads the store, and re-reading the store is an ETS
  read: free, and structurally unable to fetch.

  So `normalize/1` answers an identity and nothing else. The page reloads its
  projection from the store and highlights that identity. Trying to render
  straight out of the event would be a second, weaker copy of the entry that
  drifts from what the store actually holds.
  """

  alias Aiur.GitHub.CacheInspector.Entry
  alias Aiur.GitHub.ResourceStore

  @doc """
  Subscribes the caller to every resource type the store recognises.

  Never raises. A page that cannot subscribe must still render the cache it can
  already see: losing liveness is a degraded page, losing the page is an outage.
  """
  @spec subscribe() :: :ok
  def subscribe do
    ResourceStore.subscribe_all()
    :ok
  rescue
    _unavailable -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Turns an inbound message into `{:ok, identity}` or `:ignore`.

  Only the store's own message shape is accepted. An earlier draft of this file
  accepted several speculative shapes because the publisher did not exist yet;
  keeping them now would be worse than useless, since a shape that no longer
  matches anything hides the fact that the page has stopped updating behind a
  clause that looks like it is handling it.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :ignore
  def normalize({:github_resource_changed, %{key: {type, owner, repo, id}}}),
    do: {:ok, Entry.identity(type, to_string(owner), to_string(repo), to_string(id))}

  def normalize(_message), do: :ignore
end
