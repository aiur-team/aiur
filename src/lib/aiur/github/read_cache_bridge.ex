defmodule Aiur.GitHub.ReadCacheBridge do
  @moduledoc """
  Carries `Aiur.GitHub.ResourceStore` changes into the daemon's `ReadCache`, so
  a fact learned for free — a webhook delivery above all — retires the paid
  reads of the same resource in the same moment.

  ## Why a bridge and not the store itself

  The store and the cache are keyed differently. The store addresses a resource
  as `{type, owner, repo, id}`; the read cache keys by extracted identities —
  `{:number, owner, repo, n}`, `{:collections, owner, repo}`, `{:repo, ...}`.
  The bridge is the join: every store write publishes a change event, and this
  process turns the change into the markers the cache's freshness test consults.

  Without it, `ReadCache.invalidate_number/2` and `invalidate_repo/1` had no
  production callers — the only invalidation in the system was `write_through`,
  which covers our own writes and nothing else. A webhook delivery would leave
  its own stale read standing for the whole TTL, which is exactly why the TTLs
  had to stay at 30 seconds. The delivery is the case that matters: it arrives
  free and first, so retiring on it is the difference between "the entry is
  invalidated the moment the change happens" and "the entry is invalidated up
  to a TTL later".

  ## Which types

  The same narrow set `AgentCacheBridge` acts on, for the same reason: every
  comment and review delivery ALSO deposits the issue or pull request it hangs
  off (`Aiur.Events.GithubWebhook.Deposit.bodies/2`), so acting on the
  subresource as well would duplicate the retirement. The parent's change is
  the event, and it already names the number a reader holds.

  `invalidate_number/2` is the only function needed for that set — it retires
  both the numbered identity and the repository's collections, because a
  changed issue or pull request also changes what every enumerating read of
  that repository answers. `invalidate_repo/1` is deliberately not wired: it
  retires every read of the repository, and the four types below all name a
  number, so calling it would over-retire on every single write. A future
  repo-level change (one with no number to name) is where it belongs.

  ## Failing open

  A subscription that cannot be established, or an event shape this process
  does not recognise, leaves the cache serving entries until their TTLs close.
  That costs at most one stale window — never a failed daemon operation and
  never a lost write. The retirement itself is idempotent: a marker written
  again at a newer time only ever retires more.
  """

  use GenServer

  alias Aiur.GitHub.{ReadCache, ResourceEvents, ResourceStore}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    ResourceStore.subscribe_all()
    {:ok, %{}}
  end

  # The only store identities this acts on: the ones whose id IS the issue or
  # pull request number a cached read names. Everything else is deliberately
  # ignored, and the reason is what `Aiur.Events.GithubWebhook.Deposit` actually
  # writes — every delivery that carries a comment or a review ALSO deposits the
  # issue or pull request it hangs off, in the same call. So the parent is
  # already named by a key in this list, and acting on the comment as well would
  # add nothing except a second retirement of the same number.
  #
  # The cost of not being narrow here is not theoretical. A subresource cannot
  # name its parent from its own id, so the honest scope for it is the
  # repository's collection queries — and a busy repository sees a comment
  # every few seconds, which would retire every cached enumerating read in it
  # continuously. That is the sharing this exists for, undone, to duplicate
  # work the parent deposit has already done.
  #
  # The repo-wide comment streams (`:repo_issue_comment_stream`,
  # `:repo_review_comment_stream`) and endpoint validators
  # (`:issue_comments`) publish on every poll sweep; nothing about them moves
  # the answer a cached read could give, so they retire nothing.
  #
  # The trade-off, stated plainly: a resource type added later retires nothing
  # here until it is added to this list. That direction is chosen because the
  # other one — flushing broadly on anything unrecognised — is a certain and
  # continuous cost, while this is a bounded staleness window on a type whose
  # read nobody has taught the cache to invalidate yet.
  @invalidating_types [:issue, :pull_request, :issue_labels, :branch_pull_request]

  @impl GenServer
  def handle_info({:github_resource_changed, %{key: {type, owner, repo, id}}}, state)
      when type in @invalidating_types do
    ReadCache.invalidate_number("#{owner}/#{repo}", id)
    {:noreply, state}
  end

  def handle_info({:github_resource_changed, %{key: {_type, _owner, _repo, _id}}}, state) do
    {:noreply, state}
  end

  # A change event whose shape this process does not know. Ignored rather than
  # crashed on: the store is a cache and this is a cache of a cache, so the
  # worst an unrecognised event can be allowed to cost is a stale window.
  def handle_info({:github_resource_changed, _change}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec message() :: atom()
  def message, do: ResourceEvents.message()
end
