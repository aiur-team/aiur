defmodule Aiur.GitHub.ResourceEvents do
  @moduledoc """
  Change events for `Aiur.GitHub.ResourceStore`, so a view can learn that a
  resource moved without ever asking GitHub.

  ## Why this exists

  The dashboard is a pure reader: opening, focusing, or holding a page open
  costs zero API calls. That constraint only works if something else tells a
  page when its data changed, and the store is the one place every writer
  already meets. A webhook delivery, an agent's need-driven fetch, and an
  Aiur-originated mutation all write the same entry, so all three can wake the
  same viewer through one channel.

  The consequence worth stating plainly: a view updates because *somebody else*
  paid for the round trip. API cost becomes proportional to real change and real
  agent need, and independent of how many people are looking at how many pages.

  ## Subscribing

  Three shapes, narrowest first:

      # this exact resource
      ResourceEvents.subscribe(ResourceStore.key(:issue_comment, "aiur-team", "aiur", 42))

      # every resource of a type in one repository
      ResourceEvents.subscribe(:issue_comment, "aiur-team/aiur")

      # every resource of a type, any repository
      ResourceEvents.subscribe(:issue_comment)

  A subscriber receives `{:github_resource_changed, change}` where `change` is
  the map described by `t:change/0`. A process subscribed at more than one of
  the three scopes receives one message per matching scope; re-rendering a
  LiveView is idempotent, so the cost of that is a duplicate render rather than
  a wrong one, and the alternative — a single scope — would force every page
  watching a whole type to also enumerate identities it has not seen yet.

  ## What counts as a write

  `Aiur.GitHub.ResourceStore` funnels every write through one private `update/2`,
  so publishing there covers all of them without a writer having to remember.
  A write that leaves the entry's stored content identical — the same validator
  re-recorded by a sweep that changed nothing — publishes nothing. Only
  `recorded_at_ms` moved, no viewer can observe a difference, and a store whose
  every no-op re-rendered every subscribed page would trade the poll it just
  removed for a broadcast storm. Every write that *does* move the cached body,
  `etag`, `data_version`, `version`, `source`, or `processed_at_ms` publishes.

  The body matters most and is easy to miss: `Aiur.GitHub.ResourceStore.fetch/1`
  is the only thing that decides whether a page has anything to render, and a
  first body can land against a validator the sweep already recorded. Keying
  the change check on the ETag alone would swallow exactly the write every
  viewer is waiting for.

  Deletions are silent. `reset/0` and `forget/1` are the test seam and an
  internal eviction respectively; neither means "this resource changed
  upstream", and a view told to re-read on eviction would fetch, which is the
  behaviour this module exists to remove.

  ## Failing open

  Publishing is best-effort in exactly the way the store's reads are. No PubSub
  running — a CLI invocation, a unit test that boots no endpoint — answers `:ok`
  and writes the entry anyway. A cache that cannot announce itself must cost a
  stale view, never a lost write.
  """

  require Logger

  alias Aiur.GitHub.ResourceStore

  @pubsub Aiur.PubSub
  @message :github_resource_changed
  @prefix "github:resource"

  @typedoc """
  What a subscriber is told. `:key` is the full store identity; the flattened
  members are repeated beside it so a view can pattern match on the part it
  cares about without destructuring a tuple.
  """
  @type change :: %{
          key: ResourceStore.key(),
          resource_type: ResourceStore.resource_type(),
          owner: String.t(),
          repo: String.t(),
          id: String.t(),
          source: atom() | nil,
          version: String.t() | nil,
          etag: String.t() | nil,
          data?: boolean(),
          data_version: String.t() | nil,
          recorded_at_ms: integer()
        }

  @doc "The message tag every change event carries."
  @spec message() :: atom()
  def message, do: @message

  # -- topics ---------------------------------------------------------------

  @doc """
  The topic for one exact resource.

  Owner and repo arrive already down-cased from `ResourceStore.key/4`, which
  exists because the pipes disagree on casing; the topic inherits that so a
  subscriber and a writer that spell the repo differently still meet.
  """
  @spec topic(ResourceStore.key() | term()) :: String.t() | nil
  def topic({type, owner, repo, id}) when is_atom(type) and is_binary(owner) and is_binary(repo) and is_binary(id) do
    "#{@prefix}:#{type}:#{owner}/#{repo}:#{id}"
  end

  # A key built by hand rather than through `ResourceStore.key/4` can have a
  # member no topic can be made from. Answering `nil` keeps that out of the write
  # path: a write must never fail because the announcement could not be
  # addressed, which is the same direction every other degraded path takes.
  def topic(_key), do: nil

  @doc "The topic for every resource of `type`, in any repository."
  @spec type_topic(ResourceStore.resource_type() | term()) :: String.t() | nil
  def type_topic(type) when is_atom(type), do: "#{@prefix}:#{type}"

  # Same reason `topic/1` answers `nil`: a hand-built key can carry a type no
  # topic can be made from, and the store calls this from inside a write. Without
  # this clause that write raises `FunctionClauseError` *after* the entry has
  # already landed in ETS, so the caller — a poll task — dies holding a written
  # entry it never announced.
  def type_topic(_type), do: nil

  @doc "The topic for every resource of `type` within one repository."
  @spec type_topic(ResourceStore.resource_type(), String.t()) :: String.t() | nil
  def type_topic(type, full_name) when is_atom(type) and is_binary(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" ->
        "#{@prefix}:#{type}:#{String.downcase(owner)}/#{String.downcase(repo)}"

      _other ->
        nil
    end
  end

  def type_topic(_type, _full_name), do: nil

  # -- subscription ---------------------------------------------------------

  @doc """
  Subscribes the caller to one resource identity, or to a whole resource type.

  Answers `:ok` for a key or type it cannot address — a caller with no repo
  identity yet, a store key that could not be built — because a view that fails
  to subscribe should render the state it has rather than crash the mount.
  """
  @spec subscribe(ResourceStore.key() | ResourceStore.resource_type() | nil) :: :ok
  def subscribe(nil), do: :ok

  def subscribe({_type, _owner, _repo, _id} = key), do: do_subscribe(topic(key))

  def subscribe(type) when is_atom(type) do
    if known_type?(type), do: do_subscribe(type_topic(type)), else: unknown_type(type)
  end

  def subscribe(other), do: unknown_type(other)

  @doc "Subscribes the caller to one resource type within one `\"owner/repo\"`."
  @spec subscribe(ResourceStore.resource_type(), String.t() | nil) :: :ok
  def subscribe(type, full_name) when is_atom(type) do
    if known_type?(type), do: do_subscribe(type_topic(type, full_name)), else: unknown_type(type)
  end

  defp known_type?(type), do: type in ResourceStore.resource_types()

  # Loud, for the same reason `ResourceStore.key/4` is loud about an unlisted
  # type: nothing ever publishes to a topic for a type the store does not
  # recognise, so a view subscribed to one would simply stop updating and never
  # say why. This is that failure, named at the moment it is made.
  defp unknown_type(type) do
    Logger.error(
      "GitHub.ResourceEvents refused a subscription to unknown resource type #{inspect(type)}; " <>
        "nothing publishes to it — add it to Aiur.GitHub.ResourceStore's @resource_types"
    )

    :ok
  end

  @doc """
  Subscribes the caller to every resource type the store recognises.

  What a dashboard page wants is "tell me when GitHub state moved", and it does
  not know in advance which identities it will end up rendering. Enumerating the
  store's own type list rather than a page-local copy means a type added to the
  store reaches existing viewers without every page being edited — the failure
  mode of a page-local list is a view that silently stops updating.
  """
  @spec subscribe_all() :: :ok
  def subscribe_all do
    Enum.each(ResourceStore.resource_types(), &subscribe/1)
  end

  @doc "Reverses `subscribe/1`."
  @spec unsubscribe(ResourceStore.key() | ResourceStore.resource_type() | nil) :: :ok
  def unsubscribe(nil), do: :ok

  def unsubscribe({_type, _owner, _repo, _id} = key), do: do_unsubscribe(topic(key))

  def unsubscribe(type) when is_atom(type), do: do_unsubscribe(type_topic(type))

  def unsubscribe(_other), do: :ok

  @doc "Reverses `subscribe/2`."
  @spec unsubscribe(ResourceStore.resource_type(), String.t() | nil) :: :ok
  def unsubscribe(type, full_name) when is_atom(type), do: do_unsubscribe(type_topic(type, full_name))

  # -- publication ----------------------------------------------------------

  @doc """
  Announces that `key` now holds `entry`.

  Called by the store itself; a writer does not call this directly, because a
  writer that had to remember would eventually forget and leave a view stale
  with no way to tell.
  """
  @spec publish(ResourceStore.key() | nil, map()) :: :ok
  def publish(nil, _entry), do: :ok

  # Guarded on every member, not only on `entry`. `type_topic/2` interpolates
  # `owner` and `repo`, so a hand-built key holding anything without a
  # `String.Chars` implementation used to raise `Protocol.UndefinedError` from
  # here — before any broadcast, so the module's own rescue never saw it, and
  # after the ETS insert, so the entry was written and the writer died. A key
  # that cannot be addressed is announced to nobody instead.
  def publish({type, owner, repo, id} = key, entry)
      when is_map(entry) and is_atom(type) and is_binary(owner) and is_binary(repo) and is_binary(id) do
    change = %{
      key: key,
      resource_type: type,
      owner: owner,
      repo: repo,
      id: id,
      source: Map.get(entry, :source),
      version: Map.get(entry, :version),
      etag: Map.get(entry, :etag),
      # Whether the store now holds something renderable. A validator without a
      # body is legitimate — the sweep keeps ETags purely to learn whether
      # anything changed — so `etag` is not the question a view is asking. This
      # is. The body itself is not broadcast: it is bounded but not small, and
      # copying it to every subscriber when they can read it from ETS would
      # make fan-out cost scale with viewers, which is what this design exists
      # to stop.
      data?: not is_nil(Map.get(entry, :data)),
      data_version: Map.get(entry, :data_version),
      recorded_at_ms: Map.get(entry, :recorded_at_ms) || System.system_time(:millisecond)
    }

    message = {@message, change}

    broadcast(topic(key), message)
    broadcast(type_topic(type, "#{owner}/#{repo}"), message)
    broadcast(type_topic(type), message)

    :ok
  end

  def publish(_key, _entry), do: :ok

  # -- internals ------------------------------------------------------------

  defp do_subscribe(nil), do: :ok

  defp do_subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
    :ok
  rescue
    error -> unavailable("subscribe", topic, error)
  catch
    :exit, reason -> unavailable("subscribe", topic, reason)
  end

  defp do_unsubscribe(nil), do: :ok

  defp do_unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
    :ok
  rescue
    error -> unavailable("unsubscribe", topic, error)
  catch
    :exit, reason -> unavailable("unsubscribe", topic, reason)
  end

  defp broadcast(nil, _message), do: :ok

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
    :ok
  rescue
    error -> unavailable("broadcast", topic, error)
  catch
    :exit, reason -> unavailable("broadcast", topic, reason)
  end

  defp unavailable(action, topic, reason) do
    Logger.debug("GitHub.ResourceEvents #{action} unavailable topic=#{topic} reason=#{inspect(reason)}")
    :ok
  end
end
