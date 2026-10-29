defmodule Aiur.GitHub.ResourceStore.Docs do
  @moduledoc """
  Compile-time documentation for the public resource-store facade.
  """

  @spec resource_types() :: String.t()
  def resource_types, do: "Every resource identity this store recognises."

  @spec key() :: String.t()
  def key,
    do: """
    Builds a canonical resource key.

    `owner` and `repo` are down-cased because the two pipes disagree on casing:
    the poller uses the configured repo identity while the webhook uses GitHub's
    delivered `repository.full_name`. An exact-match store would silently miss on
    that difference and both pipes would process the same comment.

    A `resource_type` outside `resource_types/0` is **refused here and logged as
    an error**, rather than accepted and lost later. `@resource_types` is a closed
    set that `decode_key/1` resolves against, so an unlisted type would write and
    read perfectly all day and then vanish at the next restart — a body that
    disappears with no error and no way to attribute it. Refusing at the key makes
    the caller degrade to the storeless path immediately and visibly, which is the
    same failure it would eventually get, only debuggable.
    """

  @spec key_for_repo() :: String.t()
  def key_for_repo,
    do: """
    Builds a resource key from an `"owner/name"` string.

    Answers `nil` for anything that is not a two-segment repository identity, so a
    caller that cannot name its repo degrades to the storeless path rather than
    writing an entry the other pipe could never find.
    """

  @spec etag() :: String.t()
  def etag,
    do: """
    The validator to send when the point of the request is to **get the body** —
    answered only when the store can also serve that body.

    A validator handed out without its body is not a saving, it is an extra
    request: the reader spends one on `If-None-Match`, is told `304`, holds
    nothing, and has to read again unconditionally. Two requests where one was
    needed, which is the precise waste this store exists to remove. So this
    function answers exactly when `fetch/1` answers — same entry, same retention
    window — and a caller physically cannot take the validator without the body
    being there.

    That is deliberately narrower than "is there an ETag recorded". A reader that
    genuinely only needs to know *whether* something changed, and has no use for
    the body, asks `change_validator/1` and takes on the obligation described
    there.
    """

  @spec change_validator() :: String.t()
  def change_validator,
    do: """
    The recorded validator, whether or not a body is held. **Read the obligation
    before using this.**

    There is one honest use: a reader that wants to know whether a resource
    changed and has no use for its body — the oversized resource the store refuses
    to hold, where a `304` means "nothing to do" and costs nothing, and a `200`
    means "go and deal with it". For that reader this is a saving.

    For every other reader it is a trap, which is why `etag/1` does not answer
    here: a `304` against this validator returns no data, and the read has to be
    made again unconditionally. If you would be unhappy to be told "unchanged" and
    handed nothing, you want `etag/1`.

    Retention still applies: a validator on an entry past the window answers `nil`,
    because the thing it once described is gone.
    """

  @spec put_etag() :: String.t()
  def put_etag,
    do: """
    Stores a validator for `key`; a `nil` or empty one is discarded. Given `previous`, only while
    `key` still holds it: a `304` answered against `previous` vouches for no other body (#5180).

    Without a held body this leaves the moduledoc's "validator, no body" state; a caller whose
    later `304` must *answer* rather than only say "unchanged" deposits the body with `put_resource/3`.
    """

  @spec processed?() :: String.t()
  def processed?,
    do: """
    True when some pipe has already processed this exact resource *at this
    version*.

    `version` is the resource's own mutation marker — a comment's `updated_at`.
    Identity alone is not enough to decide "already handled", because a GitHub
    comment is mutable: its id is stable across an edit and only `updated_at`
    moves. Editing a ticket comment to correct an agent's instructions is a normal
    workflow here and it must re-wake the agent, so a resource whose version has
    changed since it was marked reads as unprocessed and is published again.

    Answers `false` whenever the store cannot answer, because publishing a
    duplicate is recoverable and dropping an event is not — and for the same
    reason, `false` once the mark passes its bound. A versioned mark is bounded by
    the retention window because a change releases it; an unversioned one is
    bounded by `unversioned_suppression_ms/0` because nothing else ever will.
    """

  @spec unversioned_suppression_ms() :: String.t()
  def unversioned_suppression_ms,
    do: """
    How long a mark suppresses when no version stands behind it.

    Public so the bound is assertable rather than a number buried in a private
    clause. See `@unversioned_suppression_ms`.
    """

  @spec mark_processed() :: String.t()
  def mark_processed,
    do: """
    Marks `key` processed by `source` (`:webhook` or `:poll`) at `version`.

    Recording the version is what lets a later edit of the same resource be told
    apart from a redelivery of it — and it is also what earns the mark the full
    retention window. A mark made without one is deliberately short-lived; see
    `unversioned_suppression_ms/0`.
    """

  @spec claim() :: String.t()
  def claim,
    do: """
    Marks `key` processed at `version` only if it was not already.

    Returns `:marked` for **exactly one** caller and `:already_processed` for every
    later one while the mark still suppresses, so a caller can gate a publish on
    the answer without a separate read. How long that is depends on whether a
    version stands behind the mark — see `processed?/2`.

    "Exactly one" is the whole contract, so the test and the mark happen inside a
    single compare-and-swap. Read-then-write would let two sweep passes over one
    resource both observe "not processed" and both publish, waking an agent twice
    for one human comment — which is the duplicate this function exists to stop,
    reintroduced by the gap between its two halves.
    """

  @spec put_resource() :: String.t()
  def put_resource,
    do: """
    Deposits the resource GitHub returned, and publishes the change.

    This is the writers' entry point. The cheapest writer of all is a mutation
    Aiur itself made: the response to a posted comment, an applied label or an
    edited body already carries the new state, so the round trip has been paid
    for and a later read to learn about our own change is pure waste.

    Options:

      * `:source` — which writer deposited this (`:mutation`, `:webhook`,
        `:poll`, `:fetch`). Defaults to `:mutation`.
      * `:version` — the resource's own mutation marker, its `updated_at`.
      * `:etag` — a validator for a later conditional re-read, or the atom
        `:derive` for a writer that has no validator of its own (a webhook
        delivery). `:derive` makes the store compute a content-based validator
        from the body, keeping a held validator when the body is unchanged.
      * `:processed` — when `true`, also mark the resource handled *at that
        version*, so the delivery GitHub sends moments later for this same change
        is recognised as already-processed and does not wake anybody twice. Only
        pass it with a real `:version`; a mark with no version suppresses on
        identity alone and would swallow the resource's next genuine change.

    Publishing is conditional on the resource actually differing from what is
    already held, so a writer re-depositing an unchanged body does not wake every
    subscribed view for nothing.

    A body the store will not hold — oversized, or a shape JSON cannot round-trip
    unchanged — is refused outright and the entry keeps no body, so a reader
    misses and falls back to fetching. A refused body also refuses the `:etag`
    that came with it: see the moduledoc's validator/body contract.

    `:version` describes the body being deposited, so a deposit without one records
    "version unknown" rather than keeping the previous body's version. That is
    deliberate: an old version left attached to a new body would tell the next
    reader something false, and the cost of the honest answer is at most one extra
    re-render of a subscribed view, which spends nothing upstream.
    """

  @spec deposit_unless_older() :: String.t()
  def deposit_unless_older,
    do: """
    Atomically refuses strictly older binary version markers. Equal or missing
    markers write; a superseded deposit changes no body, validator or freshness.
    """

  @spec regression?() :: String.t()
  def regression?, do: "Strictly older GitHub ISO-8601 markers regress; equal or missing markers do not."

  @spec update_resource() :: String.t()
  def update_resource,
    do: """
    Deposits a body derived from the one currently held, atomically.

    This is the writer for anything shaped "read what is there, change part of it,
    put it back" — merging labels into a held issue, folding a mutation's response
    into a fuller object. `fun` receives the held body, or `nil` when the store
    holds none, and its result is deposited exactly as `put_resource/3` would
    deposit it. Options are `put_resource/3`'s, plus `partial: true` for a write
    that replaces only some fields of the held body: `:fetched_at_ms` still moves,
    but `:full_body_at_ms` in `fetch/1`'s answer keeps the time of the last
    whole-body write.

    The read, pure and cheap `fun`, and write share one compare-and-swap. A
    concurrent writer makes it retry against the current entry, never overwrite
    from a stale read. `fun` may run more than once and must not perform IO.
    This is local to one key; checkpoint files shared by daemons remain
    last-writer-wins.

    ## What happens when the swap cannot win

    The retry budget is generous and paced, and if it is ever spent the write is
    **abandoned** — never forced. That direction is the guarantee, not a
    concession: a body derived from a read the table has already moved past is the
    rollback this function exists to prevent, and inserting it unconditionally at
    the end of the budget reintroduced it in full, `"state"` included. Abandoning
    costs a reader one full-price fetch, which is this module's documented
    fail-open direction; it is logged as an error because reaching it means
    contention far beyond anything real.

    ## Versioning a body you did not choose

    `:version` also accepts a **1-arity function**, applied to the merged body
    inside the same compare-and-swap. A fixed version cannot be correct here: the
    caller computes it before the call, from a body a concurrent writer may have
    replaced by the time `fun` re-runs, so a retry would stamp the losing read's
    marker onto the winning read's content. The result is a body labelled older
    than it is, and the next genuinely stale delivery is accepted against it —
    the rollback this function exists to prevent, one step removed.

    Every writer in this system derives a version from the body it is depositing
    (`updated_at` on an issue, a pull request, a comment), so a function of the
    merged body is the shape that is always available and always honest:

        ResourceStore.update_resource(key, &Map.put(&1, "labels", labels),
          source: :mutation,
          version: fn body -> body["updated_at"] end
        )

    A binary `:version` still behaves exactly as `put_resource/3` documents. The
    function is applied to the body actually being stored, so it sees `nil` for a
    body the store refused, and answering `nil` records "version unknown" the same
    way a missing `:version` does.

    ## Declining the write from inside the swap

    `fun` may answer `:unchanged` instead of a body, and the call then writes
    nothing at all and answers `:unchanged`. That exists so a writer whose deposit
    is *conditional* on what is held — a webhook delivery that must not overwrite a
    newer object — can make that decision where the answer is still true. The same
    decision made by reading first and depositing second is a check-then-act with a
    whole round trip in the middle: a newer body landing in that gap is overwritten
    by the older delivery, which is precisely the rollback the guard was written to
    prevent. `:unchanged` is unambiguous because a bare atom is never a storable
    body — the store refuses one, loudly, as a shape JSON cannot round-trip.

    `fun` may also be **2-arity**, receiving the held body and a small map of what
    the entry says *about* that body — `%{version: ..., fetched_at_ms: ..., etag: ...}`.
    A conditional writer needs the held marker to compare against, and reading it
    outside the call is the same check-then-act by another route.
    """

  @spec revalidate() :: String.t()
  def revalidate,
    do: """
    Records that a conditional read confirmed the held body is still current.

    This is what a `304` is allowed to write, and the restraint is the point. A
    `304` confirms **the validator this caller sent, against the body this caller
    was holding**. It says nothing whatsoever about a body some other writer
    deposited in the meantime — and since #2106 the webhook pipe deposits bodies
    for `:issue`, `:issue_labels`, `:pull_request`, `:branch_pull_request`,
    `:pr_review` and comments on every delivery, so that other writer is real and
    lands on exactly these keys.

    So the decision, made inside the swap where the answer is knowable:

      * **The body is never overwritten.** A read-then-write that re-deposits the
        body it read a moment earlier rolls a concurrent deposit back. Measured on
        `:issue`: four writers doing 150 increments each through read-then-write
        finished at 258 instead of 600.
      * **`:version` and `:source` are never re-stamped.** Both describe the body
        actually held. Stamping this caller's version onto a newer body, or
        attributing a webhook's body to a fetch, is a marker that lies — and a
        wrong `:version` is worse than a missing one, because suppression trusts it.
      * **The validator is installed only when the body is unchanged.** If a newer
        body landed, this caller's ETag no longer describes what sits beside it,
        and a mismatched validator is the bodyless-`304` hazard wearing a
        disguise: the next reader sends `If-None-Match`, is told nothing changed,
        and confidently serves the wrong body.
      * **`fetched_at_ms` moves only in the confirmed case.** When a newer body
        landed, its own `fetched_at_ms` is already newer than anything this call
        could offer.

    Answers `:confirmed` when the held body was still the one revalidated and the
    entry was refreshed, `:superseded` when a concurrent writer had already
    replaced it — in which case **nothing is written at all** and the caller should
    hand its own reader the newer body — and `:miss` when no body is held, which is
    the bodyless-`304` case the caller must resolve by re-reading unconditionally.
    """

  @spec drop_data() :: String.t()
  def drop_data,
    do: """
    Removes the held resource for `key`, leaving any validator in place.

    The validator still answers "has this changed?" cheaply. It simply cannot
    answer "what is it?" — which is why `fetch/1` answers `:miss` afterwards and
    the caller decides whether it needs the data enough to pay for it.

    This is the sanctioned "validator, no body" state, and it is only safe because
    of the reader's half of the contract in the moduledoc: a `304` against a key
    the store holds no body for must discard the validator and re-read
    unconditionally. Dropping a body without that reader behaviour converts the
    next conditional read into a spent request that returns nothing.
    """

  @spec drop_etag() :: String.t()
  def drop_etag,
    do: """
    Removes the validator for `key`, leaving any held body in place.

    The counterpart of `drop_data/1`, and the reader's half of the validator/body
    contract in the moduledoc: a reader answered `304` for a key the store holds no
    body for has spent a request for nothing, and must forget the validator so its
    next read is unconditional. Keeping it would repeat the same empty answer every
    cycle for the whole retention window.
    """

  @spec fetch() :: String.t()
  def fetch,
    do: """
    The resource held for `key`, or `:miss` when the store holds no body for it.

    A miss is not an error. It means this reader has to decide whether it needs
    the data enough to pay for it, which is the decision the store exists to make
    visible rather than automatic.

    The `:version` in the answer is the version of the **body being handed back**,
    not the version some pipe processed. Those are different facts and the entry
    keeps them apart; a reader wants to know what it is holding, and a sweep wants
    to know what has been handled.

    `:fetched_at_ms` is there so a consumer can state the staleness it tolerates
    rather than trust the store's own idea of fresh. Past the retention window the
    store declines outright, which keeps a body from outliving the entry that
    describes it if the eviction sweep has not run yet.
    """

  @spec data() :: String.t()
  def data, do: "The held resource body for `key`, or `nil`."

  @spec clear() :: String.t()
  def clear,
    do: """
    Removes every entry of one resource type in one repository.

    Clears only the selected type; shared resources are left alone. Membership
    reconciliation uses `membership_snapshot/2` and `replace_membership/4`
    instead, so newer deliveries survive and readers never see a partial set.

    Returns `:ok` even when no store is running.
    """

  @spec membership_snapshot() :: String.t()
  def membership_snapshot, do: "Captures a membership fence before an upstream reconciliation read."

  @spec replace_membership() :: String.t()
  def replace_membership, do: "Replaces membership only if no edge changed since the upstream read began."

  @spec list() :: String.t()
  def list,
    do: """
    Enumerates every entry the store holds for one resource type in one
    repository.

    This is what lets a projection treat the store as a source of truth rather
    than a per-key cache: the Build Order catalog reads all `:issue`,
    `:issue_labels`, `:sub_issue` and `:issue_dependency` entries for the active
    repository in one pass and derives the graph from them (#2313).

    Returns `[{key, entry}]` with the same entry shape `fetch/1` returns, or `[]`
    when no store is running. `owner`/`repo` are down-cased exactly as `key/4`
    down-cases them, so a caller spelling the repository either way meets the
    entries.

    No write is performed: the store table is `:public` and this reads it from
    the caller's process, except membership reads, which serialize through the
    table owner with membership writes and replacements.
    """

  @spec list_type() :: String.t()
  def list_type,
    do: """
    Lists every held body of `type` within one `"owner/repo"`.

    Answers `[{key, body}]` for the type in that repository, in arbitrary order.
    Used by event-sourced projections (the Build Order catalog) to rebuild their
    state from the store after a change event rather than holding their own copy
    of the world, and by a projection that must resolve a delivered node id to a
    held issue number.

    Only bodies that `fetch/1` would serve are returned: an expired entry and an
    entry holding no body are both omitted, so a projection rebuilding from this
    list sees exactly what a reader would have seen. A key the store would refuse
    (an unknown type, a malformed repo identity) answers `[]`.
    """

  @spec topic() :: String.t()
  def topic,
    do: """
    PubSub topic carrying changes to one resource.

    Topics live in `Aiur.GitHub.ResourceEvents`; these delegations exist so a
    caller holding a store key does not need to know that.
    """

  @spec type_topic() :: String.t()
  def type_topic, do: "PubSub topic carrying changes to every resource of one type."

  @spec subscribe() :: String.t()
  def subscribe,
    do: """
    Subscribes the caller to changes of one resource, or of a whole type.

    A subscriber receives `{:github_resource_changed, change}` and re-reads the
    store — it never fetches. That is the whole point: a view rides on whichever
    writer happened to pay, and costs nothing itself. See
    `Aiur.GitHub.ResourceEvents` for the shape of `change`.
    """

  @spec unsubscribe() :: String.t()
  def unsubscribe, do: "Unsubscribes the caller from one resource's or one type's changes."

  @spec subscribe_type() :: String.t()
  def subscribe_type, do: "Subscribes the caller to every change of one resource type."

  @spec subscribe_all() :: String.t()
  def subscribe_all, do: "Subscribes the caller to every store change."

  @spec reset() :: String.t()
  def reset,
    do: """
    Drops every entry.

    Test seam. The store is deliberately global and long-lived, which in a suite
    means one case's published comment can suppress an unrelated case that reuses
    the same fixture id — the same hazard `Aiur.Events.Publisher`'s dedup table
    already has, and the shared test setup clears both for the same reason.
    """

  @spec running?() :: String.t()
  def running?,
    do: """
    True when there is a store to read and write.

    Answered from the table every read and write funnels through, not from a
    process name: the table name is fixed while the process name is a start-up
    option. A caller that gates on the wrong one would skip its work silently
    against a store that is running.
    """

  @spec retention_ms() :: String.t()
  def retention_ms,
    do: """
    How long an entry is kept, in milliseconds.

    Exposed so a reader deciding what to call stale does not restate the number.
    A view calling an entry expired while the store still holds and serves it is
    a disagreement about the same fact, and the two would drift apart silently.
    """

  @spec size() :: String.t()
  def size, do: "Entry count, or `0` when no store is running."
end
