defmodule Aiur.Events.GithubWebhook.Deposit do
  @moduledoc """
  Writes the bodies a verified webhook delivery already carries into
  `Aiur.GitHub.ResourceStore`.

  ## Why the delivery is the right writer

  A delivery is the only writer that costs nothing. GitHub has already paid for
  the round trip, the payload is already HMAC-verified, and it arrives *first* —
  before any sweep would have read the same object. Every other writer in the
  cache spends either an API call or a mutation. So a delivery that fires an
  event and then throws its payload away has paid for a body twice: once when
  GitHub sent it, and again when some reader later fetches the same object
  because the store holds nothing for it.

  This module therefore runs on the receiving side of every delivery for a
  tracked repository, *before* the publish, so a consumer woken by the event
  finds the body already there.

  ## Shapes

  Individual comment and review events are deposited in the **poller's** shape,
  through `Aiur.Events.GithubWebhook.Triples.comment_shape/1` and
  `review_shape/1` — the same projection the normalizer publishes. That is not
  cosmetic: the store is read by consumers that must not be able to tell a
  delivered comment from a polled one, and a REST delivery carries roughly twice
  the keys the poller's GraphQL batch produces.

  Whole resources — an issue, a pull request — are deposited as GitHub's own
  object, because that is what both a conditional re-read and a mutation
  response return for them, and a consumer that later reconciles one against
  upstream must be comparing like with like. A pull request is additionally
  deposited under `:branch_pull_request`, keyed by the ticket its head branch
  belongs to, because that is the identity the one pull-request consumer reads
  by (#2126).

  Three delivery types carry state the fleet otherwise buys again, and each has
  its own clause (#2326): `pull_request_review_thread` carries a full pull
  request (deposited under both PR keys, feeding `DeliveredPullRequest`),
  `sub_issues` carries the full sub-issue and parent issue (deposited as
  carried issues), and `issue_dependencies` carries the issue plus the blocker
  edge (deposited as a carried issue, with the edge merged into the
  `:issue_blocked_by` list the dependency reader serves).

  ## What a deposit never makes servable

  **`:pr_review` and `:pr_review_comment` must never gain a cache-serving
  reader** (R10). Their bodies describe merge decisions and CI verdicts, and a
  serving reader would answer a decision from a cache. Requirement R10 says
  merge decisions, CI verdicts and dispatch gating must never be silently
  served stale, so `Aiur.GitHub.HumanReviewGate` reads them with
  `ResourceFetch.decision()` (`:strict`), where `held(_key, :strict) -> :miss`
  and the store is never consulted for an answer. That is deliberate, and it is
  recorded here so a later pass does not "complete" this work by wiring a
  serving reader for either type and breaking R10.

  For those types the prize is **"revalidates for free"**, never "served free":
  a strict read may still send `If-None-Match` — a `304` is GitHub asserting
  *right now* that the resource has not changed, a fresh answer obtained for
  free, not a cached one. Holding the body is what permits that, because
  `ResourceStore.etag/1` answers only beside a held body.

  A `check_run` delivery may advance the matching run inside a complete
  `:ci_contexts` snapshot that a poll already established for the same head.
  It never invents the rest of the collection from one run, and it never makes
  review, merge, or CI verdict fields generally cacheable. The CI poller still
  reads those strict pull-request fields and legacy commit statuses live; it
  omits only the check-run fields a newer delivery already supplied.

  ## What every deposit also retires

  A delivery is not only a body to hold — it is a fact that the state Aiur was
  caching has changed. Each deposit therefore retires the `Aiur.GitHub.ReadCache`
  identities the delivery makes stale: the numbered issue or pull request it
  carries and, unconditionally, the repository's collections. The collections
  marker goes on every delivery rather than only on actions that create or
  destroy a set member, because any change to a numbered resource changes what
  a list of that repository's tickets answers — a label changes what a
  `labels: [...]` enumeration answers, an edit changes what a ticket list
  renders — and the `build_order_catalog` enumeration names no number, so the
  collections marker is the only thing that retires it. This is
  `ReadCache.invalidate_number/2`, the same primitive `write_through/3` uses
  for Aiur's own mutations, wired to the second producer the read cache had no
  knowledge of; it is what lets the `ReadCache` TTLs rise from seconds to
  hours, with the delivery rather than the clock as the freshness mechanism and
  the clock only a backstop against a missed delivery.

  ## What this module deliberately does not do

  **It never marks anything processed** (KTD5). `put_resource/3` is called
  without `:processed`, so a deposit moves `:data_version` (the version of the
  body held) and never `:version` (the version some pipe handled). Two
  consequences, both load-bearer:

    * A delivery cannot drag a suppression mark onto a version nothing handled —
      the hazard that would silently discard an *older* sibling comment whose own
      delivery was lost.
    * `Aiur.Events.Publisher` remains the sole author of the processed mark, and
      it records it only *after* a successful publish. Depositing a body
      therefore cannot suppress an event, including for a change Aiur itself
      made: the bot self-loop filter still runs, and the body is cached while the
      event stays filtered.

  **It is a cache, never the system of record** (KTD4). Webhook loss is measured:
  9 of 100 deliveries returned 502 during a daemon restart, GitHub retried none,
  and none arrived later. A deposited entry is ordinary store content — the
  safety sweep still reads, still reconciles, and the absence of a delivery is
  never read as the absence of change.

  A `deleted` action drops the held body rather than depositing one, because
  serving a body for an object that no longer exists is worse than a miss.

  ## Ordering

  GitHub does not order deliveries, and a delivery carries more than the object
  it is about — an `issue_comment` also carries the whole issue and its label
  set. Deposits are therefore last-writer-wins with one guard: a body whose
  version is strictly older than the version already held is refused, so a
  delayed delivery cannot walk a resource backwards and then stamp it as freshly
  fetched. Equal or unknown versions still write, because a body can legitimately
  change under an unchanged marker and the later arrival is the better answer.

  One field is knowingly shared: the entry's `:source` is written both by a
  deposit ("who supplied the body I hold") and by `mark_processed/3` ("who
  handled it"), so on a resource the two pipes both touched it reports the last
  writer of either kind. Suppression does not read it; it is provenance only.
  """

  require Logger

  alias Aiur.Events.GithubWebhook.Deposit.{Bodies, CacheRetirement, StoreWrite}
  alias Aiur.GitHub.ResourceStore

  @typedoc """
  One unit of work this module produces from a delivery: either a body to
  deposit under an identity, or an identity whose held body must go.
  """
  @type work ::
          {ResourceStore.resource_type(), term(), term(), String.t() | nil}
          | {:drop, ResourceStore.resource_type(), term()}
          | {:thread_transition, term(), String.t(), map(), String.t() | nil, String.t() | nil}
          | {:invalidate_review_threads, term()}
          | {:merge_review_thread, term(), map()}
          | {:merge_check_run, term(), String.t(), map()}

  @doc """
  Deposits every body `payload` carries, and returns the keys written.

  `event_type` is the `X-GitHub-Event` header value, `repo` the tracked
  `"owner/name"` the caller already resolved. Never raises: the caller is an
  HTTP endpoint, and a cache write is never worth failing a delivery over.
  Membership-owner failures are the exception: they exit to the delivery
  handler's error boundary, because an unconfirmed edge is not a cache hit.

  Options:

    * `:at` — the delivery's arrival time, used as the version marker for the
      ordering-sensitive edge deposits (`sub_issue`, `issue_dependency`).
      GitHub's edge events carry no `updated_at` of their own, so the arrival
      time is the only honest ordering marker a stale-delivery guard can
      compare. Defaults to now.
  """
  @spec deposit(term(), term(), term(), keyword()) :: [ResourceStore.key()]
  def deposit(event_type, payload, repo, opts \\ [])

  def deposit(event_type, payload, repo, opts)
      when is_binary(event_type) and is_map(payload) and is_binary(repo) do
    keys =
      if store_running?() do
        arrival = arrival_version(opts)

        Enum.flat_map(Bodies.bodies(event_type, payload, opts), fn
          {:drop, type, id} ->
            StoreWrite.drop(type, repo, id)

          {:thread_transition, id, action, thread, generation, version} ->
            StoreWrite.store_thread_transition(repo, id, action, thread, generation, version)

          {:invalidate_review_threads, pr_number} ->
            StoreWrite.invalidate_review_threads(repo, pr_number)

          {:merge_review_thread, pr_number, thread} ->
            StoreWrite.merge_review_thread(repo, pr_number, thread)

          {:merge_check_run, target, head_sha, check_run} ->
            StoreWrite.merge_check_run(repo, target, head_sha, check_run)

          {type, id, body, version} ->
            StoreWrite.store(type, repo, id, body, edge_version(type, version, arrival))
        end)
      else
        []
      end

    CacheRetirement.invalidate_read_cache(event_type, payload, repo)
    keys
  rescue
    error ->
      Logger.warning("GithubWebhook.Deposit skipped type=#{inspect(event_type)} error=#{Exception.message(error)}")
      []
  catch
    :exit, {:membership_unavailable, _reason} = failure ->
      exit(failure)

    kind, reason ->
      # The caller absorbs a throw or exit as `%{status: :error}` for the whole
      # delivery. A cache write is never worth that, so it is caught here too.
      Logger.warning("GithubWebhook.Deposit skipped type=#{inspect(event_type)} reason=#{inspect({kind, reason})}")

      []
  end

  def deposit(_event_type, _payload, _repo, _opts), do: []

  # Only the two graph-edge types carry no `updated_at` and are
  # ordering-sensitive, so only they fall back to the delivery's arrival time
  # as their version marker. Every other type keeps the version its `bodies/2`
  # clause supplied, which may legitimately be `nil` — a PR review has no
  # `updated_at` — and forcing an arrival time onto those would change their
  # stored marker and break consumers that read it (#2313).
  defp edge_version(type, nil, arrival) when type in [:sub_issue, :issue_dependency], do: arrival
  defp edge_version(_type, version, _arrival), do: version

  # The ISO-8601 arrival marker used as an edge's version. UTC timestamps sort
  # lexically, which is exactly what `regression?/2`'s `<` comparison needs.
  defp arrival_version(opts) do
    case Keyword.get(opts, :at) do
      %DateTime{} = at -> DateTime.to_iso8601(at)
      _other -> DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  # A store that is not running accepts every write into nothing and would then
  # be reported as a refusal by `confirm/1` for every body in the delivery.
  # Answered once per delivery instead — through the store's own view, which is
  # the table the writes land in.
  defp store_running?, do: ResourceStore.running?()
end
