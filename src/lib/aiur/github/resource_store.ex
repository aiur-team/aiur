defmodule Aiur.GitHub.ResourceStore do
  @moduledoc """
  Restart-durable GitHub state keyed by **resource identity**, not by call site.

  Aiur learns the same GitHub fact through more than one pipe. A comment arrives
  free over a webhook and is then read again, at full price, by the comment poll
  sweep. `Aiur.Events.GitHubWebhook.Normalizer` already reduces a delivery to
  keys "taken one for one from `CommentPollBatch.normalize_comments/1`" so that
  consumers cannot tell the two apart — which is the proof that they are the
  same event, and therefore that one of the two reads is waste.

  This store is where the pipes meet. Every entry is addressed by
  `{resource_type, owner, repo, id}`, so a comment written by the webhook pipe
  and the same comment seen by the poll sweep resolve to one entry regardless of
  which API shape produced it. Keying by call site instead would make the entry
  unreadable from the other pipe, which is the whole point.

  ## What an entry holds

    * `:etag` — the validator for a conditional re-read. A `304` costs nothing
      against GitHub's primary REST limit, so a sweep over unchanged resources
      is free rather than merely cheap.
    * `:processed_at_ms` — the moment some pipe finished processing this exact
      resource. This is the suppress half of the sweep.
    * `:version` — the resource's own mutation marker, a comment's `updated_at`.

  ## Identity says *which* resource; version says *which state of it*

  A GitHub comment is mutable. An edit keeps the id and moves only `updated_at`,
  and the sweep's `?since=` filter is on `updated_at`, so an edited comment comes
  back around on the next cycle. Suppressing on identity alone would read that as
  a redelivery of the original and swallow it for the full retention window —
  three days, across restarts. Editing a comment to correct an agent's
  instructions is a normal workflow here, so that would be a real loss.

  So a mark records the version it was made at, and a resource whose version has
  moved reads as unprocessed. Note this is *not* a watermark: nothing is compared
  for order, only for equality against the version that was actually processed.
  An older lost comment still recovers, because it is a different resource
  entirely.

  Shortening the retention window would have bought the edit back by giving up
  the thing the window exists for — a delivery GitHub retries up to three days
  later — so the version is recorded instead.

  Suppression is nevertheless **bounded**, and the bound depends on whether a
  version stands behind the mark. A versioned mark is released by the resource
  changing, so the clock does not have to release it and it may hold for the full
  retention window. A mark with no version can only ever be released by the
  clock, so it holds for `unversioned_suppression_ms/0` instead — otherwise one
  mapping mistake hides a resource for three days with nothing to attribute it
  to. See `@unversioned_suppression_ms`.

  ## Suppress and recover are not in tension once the key is identity

  The sweep must not re-process what the webhook already delivered, and it must
  still recover a delivery that was lost. Measured here: 9 of 100 deliveries
  returned 502 during a daemon restart, GitHub retried none, and none arrived
  later. Those two requirements only fight each other if suppression is decided
  by a *timestamp watermark* — "ignore anything older than the newest thing I
  saw" also ignores an older sibling whose delivery was dropped.

  Deciding per resource identity removes the conflict outright. A comment the
  webhook processed is marked and is skipped by name; a comment whose delivery
  was lost was never marked, so the very next sweep publishes it. The sweep
  itself is never skipped, so there is no window in which a gap cannot be seen.

  ## Failing open

  Every fault — no state directory, unwritable file, corrupt document, dead
  process — degrades to the pre-store behavior: `etag/1` answers `nil` (so the
  read is unconditional, exactly as before), `processed?/1` answers `false` (so
  the event is published, exactly as before). A cache that cannot answer must
  cost throughput, never correctness, and the safe direction is a duplicate the
  publisher's own dedup window still catches — never a dropped event.

  ## Retention

  Entries expire after 72 hours, matching `Aiur.Webhooks.DeliveryLog`: that is
  the envelope inside which GitHub will still retry a delivery, so it is the
  window in which a duplicate can still legitimately arrive.

  ## Holding the resource, not only the validator

  An entry may also hold the resource's own `:data` — the object GitHub
  returned. A validator alone is not enough to satisfy a second consumer: an
  ETag shared without the body earns that consumer a `304` and no data, which
  converts a duplicate fetch into a dropped read. The body is what makes a
  reader able to answer without spending.

  `put_resource/3` is how a writer deposits one, and every write that changes
  what a reader could observe publishes a `Aiur.GitHub.ResourceEvents` change
  event to the subscribers of that resource, of its type in that repository, and
  of its type anywhere. That is what lets a view re-render off somebody else's
  write instead of paying for a read of its own.

  ## The validator/body contract — read this before adding a reader

  A validator and a body are separable, and the separation is what makes a
  `304` dangerous. Three states exist and each one binds the reader differently:

    * **body + validator** — the normal state after `put_resource/3`. A `304`
      means "what you hold is current": serve the held body and publish exactly
      what a `200` would have. This is the only state in which a conditional
      request is free *and* answers the question.
    * **validator, no body** — legitimate and deliberately reachable.
      `put_etag/2` records one, and `drop_data/1` removes a body while leaving
      the validator in place on purpose. A reader in this state that sends
      `If-None-Match` and is answered `304` has **spent a request and learned
      nothing**, and has to read again unconditionally: two requests where one
      was needed. **So the store does not offer this validator to a reader of
      bodies at all.** `etag/1` answers exactly when `fetch/1` answers, and a
      reader that genuinely only wants change detection asks
      `change_validator/1` by name and accepts that a `304` hands it nothing.
      That is enforcement rather than instruction, because the raw accessor was
      an invitation and two call sites took it.
    * **body, no validator** — a deposit whose writer had no ETag for a body
      that changed, or a validator the entry lost for the reason above. Costs
      one full-price read. Always safe.

  Two rules keep those states honest, both enforced rather than documented:

    * **A validator is never recorded for a body the store refused**, at deposit
      time *or* at checkpoint time. See `deposit_etag/4` and `encode_fields/2`.
    * **A validator never outlives the body it describes.** A deposit that
      supplies no validator keeps the held one only while the body is unchanged;
      a *different* body discards it, because a validator that describes
      something the store no longer holds guarantees every later conditional
      read misses — the entry could never earn a `304` again. A webhook delivery
      is exactly that case: a fresh body and no validator of any kind.

  ## A refusal never destroys what is already held

  "I cannot hold what you sent" and "what you are holding is wrong" are
  different statements. An oversized or unencodable arrival is refused and the
  entry keeps its existing body, its version and its `fetched_at_ms` — throwing
  a good body away would make the next reader buy it again, and would leave the
  old validator beside no body at all.

  ## Versioning a read-modify-write: `:version` must be a function

  For `update_resource/3` on any resource whose ordering matters, pass
  `:version` as a **1-arity function of the merged body**, never a fixed string:

      ResourceStore.update_resource(key, &Map.put(&1, "labels", labels),
        version: fn body -> body["updated_at"] end
      )

  A static version is *structurally* wrong there, not merely risky. The caller
  computes it before the call, from a body a concurrent writer may have replaced
  by the time the merge re-runs inside the compare-and-swap — so a retry stamps
  the losing read's marker onto the winning read's content. Nothing raises. The
  body is simply labelled older than it is, and the next genuinely stale
  delivery is accepted against that wrong marker: the rollback the
  compare-and-swap exists to prevent, displaced one step into the metadata. The
  correct version cannot be known until the merge has run, and the merge only
  runs inside the swap, so the version has to be derived there too.

  ## A body with no version disarms the staleness guards downstream

  Worse than a missing marker is a `nil` one, and it is worth stating because
  the failure is silent at every level.
  `Aiur.Events.GitHubWebhook.Deposit.regression?/2` refuses an out-of-order
  delivery only when it has a binary marker on **both** sides, so a single
  version-less deposit does not weaken that guard for the resource — it switches
  it off, and every later late delivery lands. Deposit a version for anything a
  second pipe also writes. The store warns when a body is stored without one for
  an identity where ordering decides correctness (`@order_sensitive_types`),
  for the same reason an unlisted resource type is loud: the alternative is
  discovering it two units later, by accident.

  ## Changing a held body: never fetch-then-put

  A writer that reads the held body, changes part of it and puts it back must
  use `update_resource/3`, which does all three inside one compare-and-swap.
  The same thing written as `fetch/1` followed by `put_resource/3` loses writes
  within the first handful of concurrent merges, because the window is a whole
  round trip through the caller: a webhook delivery depositing the fresh object
  in between is overwritten by the stale snapshot, `"state"` included. There is
  no volume threshold below which this is safe.

  ## Bodies must be JSON that round-trips unchanged

  A checkpointed body has to come back the shape it went in. `Jason` does not
  preserve atom map keys, atoms, tuples or structs, so a body containing any of
  them would work in memory and come back differently after a restart — a
  consumer matching `%{id: id}` would start raising with nothing to attribute it
  to. `put_resource/3` therefore **refuses** such a body, loudly, and holds no
  body at all rather than one that will change under the reader. GitHub REST
  responses are string-keyed JSON, so nothing a pipe deposits is affected.

  ## Which pipe wrote is not a change

  `:source` records the pipe that last marked a resource processed and
  `:data_source` the pipe that deposited the body; they are separate fields
  because one deposit and one mark used to overwrite each other's answer.
  Neither is part of what counts as a change. Two readers of the same unchanged
  resource — the ticket-detail path writing `:fetch` and the poll writing
  `:poll` — would otherwise alternate that field on every cycle and wake every
  subscriber of a resource that did not move. A subscriber that wants to know
  who paid reads it off the change event.

  ## Who writes and who reads today

  Deliberately recorded so a later unit does not assume more than exists.
  Writers: `Aiur.Events.GithubCommentsPoller` deposits each watched target's
  comment *lists* as bodies with the endpoint's validator,
  `Aiur.Orchestrator.CommandScan` deposits the two repo-wide comment streams the
  same way, `Aiur.Events.GitHubWebhook.Deposit` deposits delivered issues, labels,
  pull requests and the open pull request for a ticket's head branch,
  `Aiur.GitHub.ResourceFetch` deposits what it fetches, mutation write-through
  merges its own responses, `Aiur.GitHub.PollSnapshots` converges complete
  review-thread and CI-context selections, and `Aiur.Events.Publisher` marks
  individual comment resources processed. Readers: the poller and the
  command scan both serve their own `304` from the held list, `Aiur.GitHub.Issues`
  and the dashboard read bodies, and the three GraphQL poll paths consult
  delivery-fresh selection snapshots before spending.

  ## Two versions, deliberately kept apart

  `:version` is the version at which some pipe *processed* the resource, and it
  is the suppress half of the sweep. `:data_version` is the version of the body
  currently held. They are stored separately because merging them would be a
  suppression bug: a writer depositing newer data would otherwise silently drag
  an older processed-mark forward onto a version nothing has handled, and the
  event for that version would never be published. A deposit only advances
  `:version` when its caller passes `processed: true`, meaning "I have already
  done whatever this resource requires".
  """

  use GenServer

  require Logger

  alias Aiur.{Config, Fs, JsonStore}
  alias Aiur.GitHub.ResourceEvents

  @table __MODULE__.Table
  @retention_ms 72 * 60 * 60 * 1000
  @sweep_interval_ms 5 * 60 * 1000
  @checkpoint_interval_ms 30 * 1000
  @filename "github_resources.json"
  @max_entries 100_000

  # The bound on suppression that has no version behind it.
  #
  # A *versioned* mark is safe to hold for the whole retention window because a
  # genuine change moves the version and unsuppresses the resource immediately —
  # time is not what releases it. A mark with **no** version cannot be released
  # that way at all: it suppresses on identity alone, so nothing the resource
  # does will ever unsuppress it and its only bound is the clock. Leaving that at
  # 72 hours means one mapping mistake — a writer that cannot read a version,
  # a resource shape whose marker moved — hides the resource for three days,
  # across restarts, with no error and nothing to attribute it to.
  #
  # 30 minutes is far longer than any duplicate-delivery burst (GitHub's
  # immediate retries are seconds apart) and short enough that a mistake costs
  # one delayed wake rather than a lost one. The failure this trades into is a
  # duplicate publish, which the publisher's own dedup window already absorbs,
  # and which every other trade-off in this module also chooses over a drop.
  @unversioned_suppression_ms 30 * 60 * 1000

  # A single GitHub issue, pull request or comment body is a few kilobytes and
  # GitHub itself caps an issue body at 64 KiB, so nothing legitimate here comes
  # close. A resource that does is not cached at all: an entry that large would
  # be paid for on every checkpoint, and the reader falling back to a fetch is
  # exactly the pre-store behavior.
  @max_data_bytes 256 * 1024

  # The closed set of resource identities. Declared here rather than left to
  # whichever module happens to be loaded first, because `decode_key/1` resolves
  # a checkpointed type with `String.to_existing_atom/1` and would otherwise
  # drop entries for a type whose only mention lives in a not-yet-loaded module.
  @resource_types [
    # Individual events — the identity both pipes agree on, used to decide
    # whether this exact comment/review has already been processed.
    :issue_comment,
    :pr_review_comment,
    :pr_review,
    # Whole resources — the identity a reader asks for and a mutation returns.
    :issue,
    :issue_labels,
    :pr_review_thread,
    # Build Order relationship edges — the `sub_issues` and `issue_dependencies`
    # webhook deliveries keyed per relationship so an event-sourced catalog can
    # rebuild its roots' membership from the store instead of polling GitHub.
    # `:sub_issues` is keyed by the sub-issue number and `:issue_dependencies`
    # by the dependency relationship id.
    :sub_issues,
    :issue_dependencies,
    # Complete selection families shared by the GraphQL pollers and webhook
    # deltas. They deliberately exclude strict review/merge verdict fields.
    :pr_review_threads,
    :ci_contexts,
    # Endpoint reads — the identity a conditional request validator belongs to.
    :issue_comments,
    :pr_issue_comments,
    # The two repo-wide comment streams. `Aiur.Orchestrator.CommandScan` used to
    # keep their validators under its own call-site names, so its cached state
    # was private to that one caller and died with the orchestrator's memory. The
    # streams are a property of the repository, not of the scan, so they are
    # named here and shared like everything else.
    :repo_issue_comment_stream,
    :repo_review_comment_stream,
    :pull_request,
    :pull_request_reviews,
    :labelled_pull_requests,
    # The open pull request belonging to a ticket's head branch. Keyed by the
    # ticket number rather than the PR number, because that is the only identity
    # the caller holds before the lookup answers.
    :branch_pull_request,
    # The conditional validator for that lookup's open-pull-request listing
    # (`GET /pulls?state=open`), held separately from `:branch_pull_request`.
    # The three writers of the PR-body key — webhook deposit, human-review gate,
    # and the per-cycle Client lookup — each write a different kind of validator,
    # so sharing one key would clobber the listing's page-1 ETag with a
    # PR-body-derived hash it can never match (#2126, #2298).
    :branch_pull_request_listing
  ]

  # The identities where a body's *order* decides correctness: a whole mutable
  # resource that arrives from more than one pipe, where a late delivery can roll
  # state back. These are the ones a version-less deposit quietly disarms, so
  # they are the ones the store says something about. An endpoint list carries no
  # marker of its own and is not ordered against anything.
  #
  # `:branch_pull_request` is written by both the webhook deposit and
  # `Aiur.GitHub.ResourceFetch` (the human-review gate's strict read stores its
  # fetch), so a late delivery can roll the held PR back — the same reason
  # `:pull_request` is here. `:check_run` was removed from the store entirely
  # when its deposit was ceased (#2126); a CI verdict is never cached.
  @order_sensitive_types [:issue, :issue_labels, :pull_request, :pr_review_thread, :branch_pull_request]

  @type resource_type :: atom()
  @type key :: {resource_type(), String.t(), String.t(), String.t()}
  @type entry :: %{
          data: term(),
          version: String.t() | nil,
          source: atom() | nil,
          fetched_at_ms: integer() | nil,
          etag: String.t() | nil
        }

  # The stored entry keeps two `source` facts apart: `:source` is the pipe that
  # last marked the resource processed, `:data_source` is the pipe that
  # deposited the body. They used to be one field, so a deposit and a mark
  # overwrote each other's answer.

  @doc "Every resource identity this store recognises."
  @spec resource_types() :: [resource_type()]
  def resource_types, do: @resource_types

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
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
  @spec key(resource_type(), String.t(), String.t(), term()) :: key() | nil
  def key(resource_type, owner, repo, id) when is_atom(resource_type) and is_binary(owner) and is_binary(repo) do
    if resource_type in @resource_types do
      case normalize_id(id) do
        nil -> nil
        normalized -> {resource_type, String.downcase(owner), String.downcase(repo), normalized}
      end
    else
      Logger.error(
        "GitHub.ResourceStore refused unknown resource type #{inspect(resource_type)}; " <>
          "add it to Aiur.GitHub.ResourceStore's @resource_types or entries for it will not survive a restart"
      )

      nil
    end
  end

  def key(_resource_type, _owner, _repo, _id), do: nil

  @doc """
  Builds a resource key from an `"owner/name"` string.

  Answers `nil` for anything that is not a two-segment repository identity, so a
  caller that cannot name its repo degrades to the storeless path rather than
  writing an entry the other pipe could never find.
  """
  @spec key_for_repo(resource_type(), String.t() | nil, term()) :: key() | nil
  def key_for_repo(resource_type, full_name, id) when is_binary(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" -> key(resource_type, owner, repo, id)
      _other -> nil
    end
  end

  def key_for_repo(_resource_type, _full_name, _id), do: nil

  @doc """
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
  @spec etag(key() | nil) :: String.t() | nil
  def etag(nil), do: nil

  def etag(key) do
    case fetch(key) do
      {:ok, %{etag: etag}} when is_binary(etag) and etag != "" -> etag
      _other -> nil
    end
  end

  @doc """
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
  @spec change_validator(key() | nil) :: String.t() | nil
  def change_validator(nil), do: nil

  def change_validator(key) do
    case lookup(key) do
      %{etag: etag} = entry when is_binary(etag) and etag != "" ->
        if expired?(Map.get(entry, :recorded_at_ms) || 0), do: nil, else: etag

      _other ->
        nil
    end
  end

  @doc """
  Stores a validator for `key`. A `nil` or empty validator is discarded.

  This leaves the entry in the "validator, no body" state described in the
  moduledoc unless a body is already held. A caller that wants a later `304` to
  be able to *answer* rather than only say "unchanged" deposits the body with
  `put_resource/3` instead.
  """
  @spec put_etag(key() | nil, String.t() | nil) :: :ok
  def put_etag(nil, _etag), do: :ok
  def put_etag(_key, etag) when not is_binary(etag) or etag == "", do: :ok

  def put_etag(key, etag) do
    update(key, fn entry -> Map.put(entry, :etag, etag) end)
  end

  @doc """
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
  @spec processed?(key() | nil, String.t() | nil) :: boolean()
  def processed?(key, version \\ nil)

  def processed?(nil, _version), do: false

  def processed?(key, version) do
    processed_entry?(lookup(key), normalize_version(version))
  end

  # One definition of "already handled", shared by the read and by `claim/3`'s
  # compare-and-swap. Two copies of this predicate is how the two answers drift
  # apart, and a `claim/3` that disagreed with `processed?/2` would suppress an
  # event nothing had published.
  #
  # The bound lives here rather than in `processed?/2` for exactly that reason:
  # `claim/3` consults this predicate directly inside its swap, so a bound
  # applied only on the read path would leave the atomic claim suppressing
  # unversioned marks for the full retention window.
  defp processed_entry?(%{processed_at_ms: at} = entry, version) when is_integer(at) do
    marked = Map.get(entry, :version)
    marked == version and within_suppression_bound?(at, marked)
  end

  defp processed_entry?(_entry, _version), do: false

  @doc """
  How long a mark suppresses when no version stands behind it.

  Public so the bound is assertable rather than a number buried in a private
  clause. See `@unversioned_suppression_ms`.
  """
  @spec unversioned_suppression_ms() :: pos_integer()
  def unversioned_suppression_ms, do: @unversioned_suppression_ms

  @doc """
  Marks `key` processed by `source` (`:webhook` or `:poll`) at `version`.

  Recording the version is what lets a later edit of the same resource be told
  apart from a redelivery of it — and it is also what earns the mark the full
  retention window. A mark made without one is deliberately short-lived; see
  `unversioned_suppression_ms/0`.
  """
  @spec mark_processed(key() | nil, atom(), String.t() | nil) :: :ok
  def mark_processed(key, source, version \\ nil)

  def mark_processed(nil, _source, _version), do: :ok

  def mark_processed(key, source, version) when is_atom(source) do
    # Said out loud, because this is the mapping mistake the bound exists to
    # bound: a writer that could not read a version suppresses on identity alone,
    # and the only evidence anything went wrong is this line. `deposit/5` already
    # warns for the same case on the write path.
    if is_nil(normalize_version(version)) do
      Logger.warning(
        "GitHub.ResourceStore marked #{inspect(key)} processed with no version; " <>
          "suppression falls back to identity alone and expires after #{div(@unversioned_suppression_ms, 60_000)} minutes"
      )
    end

    update(key, fn entry ->
      entry
      |> Map.put(:processed_at_ms, now_ms())
      |> Map.put(:source, source)
      |> Map.put(:version, normalize_version(version))
    end)
  end

  @doc """
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
  @spec claim(key() | nil, atom(), String.t() | nil) :: :marked | :already_processed
  def claim(key, source, version \\ nil)

  def claim(nil, _source, _version), do: :marked

  def claim(key, source, version) when is_atom(source) do
    version = normalize_version(version)

    update_reply(key, :marked, fn existing ->
      if processed_entry?(existing, version) do
        {existing, :already_processed}
      else
        {existing
         |> Map.put(:processed_at_ms, now_ms())
         |> Map.put(:source, source)
         |> Map.put(:version, version), :marked}
      end
    end)
  end

  @doc """
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
  @spec put_resource(key() | nil, term(), keyword()) :: :ok
  def put_resource(key, data, opts \\ [])

  def put_resource(nil, _data, _opts), do: :ok

  def put_resource(key, data, opts) do
    update_resource(key, fn _held -> data end, opts)
    :ok
  end

  @doc """
  Deposits a body derived from the one currently held, atomically.

  This is the writer for anything shaped "read what is there, change part of it,
  put it back" — merging labels into a held issue, folding a mutation's response
  into a fuller object. `fun` receives the held body, or `nil` when the store
  holds none, and its result is deposited exactly as `put_resource/3` would
  deposit it. Options are `put_resource/3`'s.

  ## The concurrency guarantee, stated plainly

  A caller that does the same thing with `fetch/1` followed by `put_resource/3`
  **loses writes**, and not rarely: two processes merging into one `:issue` key
  regressed the held body within the first twenty writes. The read-modify-write
  spans an entire round trip through the caller, so anything deposited in
  between — a webhook delivery carrying the fresh object, another mutation's
  response — is overwritten by the stale snapshot the loser read first. The
  rolled-back fields include `"state"`, so a reader can be handed `open` for a
  ticket Aiur has closed: a correctness failure on dispatch-relevant state, not
  cosmetic staleness. Worse, a merge that deposits with no `:version` writes
  `data_version: nil` in the same breath, so nothing marks the body as older
  than what it replaced.

  This function closes that window: the read, `fun`, and the write are one
  compare-and-swap against the exact entry that was read (`:ets.select_replace/2`,
  or `:ets.insert_new/2` when the entry is absent). A concurrent write makes this
  call re-read and re-apply `fun`, so both writes survive and the held body never
  goes backwards.

  **`fun` must therefore be pure and cheap** — it can run more than once, and it
  must not perform IO, spend an API call, or depend on anything but its
  argument. It sees the held body only while it is still current; anything
  needing the wider world happens before the call and is passed in.

  The guarantee is scoped to this store's entry for one key. It is not a
  distributed lock: two daemons on one checkpoint file still resolve by
  last-writer-wins at checkpoint time.

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
  @spec update_resource(key() | nil, (term() -> term()) | (term(), map() -> term()), keyword()) :: :ok | :unchanged
  def update_resource(key, fun, opts \\ [])

  def update_resource(nil, _fun, _opts), do: :ok

  def update_resource(key, fun, opts) when is_function(fun, 1) or is_function(fun, 2) do
    source = Keyword.get(opts, :source, :mutation)
    version = Keyword.get(opts, :version)

    update_reply(key, :ok, fn existing ->
      case merge(fun, existing) do
        :unchanged ->
          {:skip, :unchanged}

        merged ->
          storable = storable_data(key, merged)
          resolved = resolve_version(version, stored_body(storable))
          warn_unversioned(key, storable, resolved)
          {deposit(existing, storable, source, resolved, opts), :ok}
      end
    end)
  end

  defp merge(fun, existing) when is_function(fun, 1), do: fun.(held_body(existing))

  defp merge(fun, existing) do
    fun.(held_body(existing), %{
      version: Map.get(existing, :data_version),
      fetched_at_ms: Map.get(existing, :fetched_at_ms),
      etag: Map.get(existing, :etag)
    })
  end

  # A body with no version disarms every downstream staleness guard for that
  # resource, silently. `Aiur.Events.GitHubWebhook.Deposit.regression?/2` needs a
  # binary marker on *both* sides to refuse a late delivery, so one version-less
  # deposit makes every later out-of-order delivery for that key acceptable — the
  # guard is not weakened, it is switched off, and nothing says so.
  #
  # Only said out loud for the identities where ordering decides correctness: a
  # whole mutable resource whose state a stale delivery can roll back. An
  # endpoint list has no marker of its own and is not ordered against anything,
  # so warning about those would be noise that trains the reader to ignore this.
  defp warn_unversioned(key, {:ok, data}, nil) when not is_nil(data) do
    case key do
      {type, _owner, _repo, _id} when type in @order_sensitive_types ->
        Logger.warning(
          "GitHub.ResourceStore stored a body for #{inspect(key)} with no version; " <>
            "downstream staleness guards cannot refuse a late delivery for it"
        )

      _other ->
        :ok
    end
  end

  defp warn_unversioned(_key, _storable, _version), do: :ok

  # A refused arrival stores nothing, so a `:version` function is applied to
  # `nil` — it never describes the body the entry is still holding.
  defp stored_body({:ok, data}), do: data
  defp stored_body(:refused), do: nil

  # Resolved inside the caller's critical section, never before it, so a retry
  # re-derives the marker from the body that actually won the swap.
  defp resolve_version(version, body) when is_function(version, 1), do: normalize_version(version.(body))
  defp resolve_version(version, _body), do: normalize_version(version)

  # `fun` is handed what a reader would have been handed, which means an expired
  # body is `nil` here for the same reason `fetch/1` declines it: merging into a
  # body nothing has revalidated for three days would resurrect it under a fresh
  # `fetched_at_ms`.
  defp held_body(entry) do
    case Map.get(entry, :data) do
      nil -> nil
      data -> if expired?(Map.get(entry, :fetched_at_ms) || 0), do: nil, else: data
    end
  end

  @doc """
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
  @spec revalidate(key() | nil, term(), String.t() | nil) :: :confirmed | :superseded | :miss
  def revalidate(key, confirmed_data, etag)

  def revalidate(nil, _confirmed_data, _etag), do: :miss

  def revalidate(key, confirmed_data, etag) do
    update_reply(key, :miss, fn existing ->
      case held_body(existing) do
        nil ->
          {existing, :miss}

        ^confirmed_data ->
          # One rule, one helper, both callers: a validator may only sit beside
          # the body it describes. Here the body is by definition unchanged —
          # that is what this clause matched on — so the validator this `304`
          # confirmed is installed. A deposit reaches the same helper from the
          # other direction and discards a held validator when the body moved.
          {existing
           |> Map.put(:fetched_at_ms, now_ms())
           |> deposit_etag(confirmed_data, confirmed_data, etag), :confirmed}

        _newer ->
          {existing, :superseded}
      end
    end)
  end

  @doc """
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
  @spec drop_data(key() | nil) :: :ok
  def drop_data(nil), do: :ok

  def drop_data(key) do
    update(key, fn entry -> entry |> Map.delete(:data) |> Map.delete(:data_version) end)
  end

  @doc """
  Removes the validator for `key`, leaving any held body in place.

  The counterpart of `drop_data/1`, and the reader's half of the validator/body
  contract in the moduledoc: a reader answered `304` for a key the store holds no
  body for has spent a request for nothing, and must forget the validator so its
  next read is unconditional. Keeping it would repeat the same empty answer every
  cycle for the whole retention window.
  """
  @spec drop_etag(key() | nil) :: :ok
  def drop_etag(nil), do: :ok

  def drop_etag(key) do
    # Decided *inside* the swap, on the raw `:etag` field, and both halves of that
    # matter.
    #
    # Inside, because the check "is there a validator to forget" and the act of
    # forgetting it used to be two operations with a whole read/write gap between
    # them: a concurrent `put_etag/2` landing in the gap was answered `:ok` by a
    # call that then dropped nothing, and a validator the caller was told had been
    # forgotten stayed and repeated the same empty `304` every cycle. `:skip` is
    # what lets the swap decline to write at all, so forgetting a validator
    # nothing holds still does not create an empty entry for the key.
    #
    # On the raw field, because `etag/1` deliberately answers only when a body is
    # held — so asking it here made this function a no-op in the one state it
    # exists for. A reader answered `304` for a key the store holds *no* body for
    # is the bodyless-validator case; that is precisely the validator that has to
    # go.
    update_reply(key, :ok, fn entry ->
      if is_nil(Map.get(entry, :etag)) do
        {:skip, :ok}
      else
        {Map.delete(entry, :etag), :ok}
      end
    end)
  end

  @doc """
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
  @spec fetch(key() | nil) :: {:ok, entry()} | :miss
  def fetch(nil), do: :miss

  def fetch(key) do
    case lookup(key) do
      %{data: data} = entry when not is_nil(data) ->
        # Judged on when the *body* was recorded, never on `:recorded_at_ms`:
        # every write touches that field, so a sweep re-recording an unchanged
        # validator would keep a three-day-old body servable forever.
        if expired?(Map.get(entry, :fetched_at_ms) || 0) do
          :miss
        else
          {:ok,
           %{
             data: data,
             version: Map.get(entry, :data_version),
             # The pipe that deposited *this body*. Kept apart from `:source`,
             # which records the pipe that last marked the resource processed:
             # one deposit and one mark used to overwrite each other's answer,
             # so a reader asking "where did this body come from" could be told
             # about a mark instead. Falls back for entries written before the
             # split.
             source: Map.get(entry, :data_source) || Map.get(entry, :source),
             fetched_at_ms: Map.get(entry, :fetched_at_ms),
             etag: Map.get(entry, :etag)
           }}
        end

      _other ->
        :miss
    end
  end

  @doc "The held resource body for `key`, or `nil`."
  @spec data(key() | nil) :: term()
  def data(key) do
    case fetch(key) do
      {:ok, %{data: data}} -> data
      :miss -> nil
    end
  end

  @doc """
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
  @spec list_type(resource_type(), String.t() | nil) :: [{key(), term()}]
  def list_type(type, full_name) when is_atom(type) and is_binary(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] when owner != "" and repo != "" and type in @resource_types ->
        # `match_object/2` matches whole stored objects (`{key, entry}`), so the
        # pattern wraps the key in the tuple that is actually stored.
        pattern = {{type, String.downcase(owner), String.downcase(repo), :_}, :_}

        with_table([], fn table -> list_type_entries(table, pattern) end)

      _other ->
        []
    end
  end

  def list_type(_type, _full_name), do: []

  defp list_type_entries(table, pattern) do
    table
    |> :ets.match_object(pattern)
    |> Enum.flat_map(&type_entry/1)
  end

  defp type_entry({key, entry}) do
    case held_entry(entry) do
      nil -> []
      data -> [{key, data}]
    end
  end

  # The same expiry rule `fetch/1` applies, so a projection rebuilding from
  # `list_type/2` never serves a body the store itself would have declined.
  defp held_entry(entry) do
    case Map.get(entry, :data) do
      nil ->
        nil

      data ->
        if expired?(Map.get(entry, :fetched_at_ms) || 0), do: nil, else: data
    end
  end

  @doc """
  PubSub topic carrying changes to one resource.

  Topics live in `Aiur.GitHub.ResourceEvents`; these delegations exist so a
  caller holding a store key does not need to know that.
  """
  @spec topic(key()) :: String.t() | nil
  defdelegate topic(key), to: ResourceEvents

  @doc "PubSub topic carrying changes to every resource of one type."
  @spec type_topic(resource_type()) :: String.t() | nil
  defdelegate type_topic(type), to: ResourceEvents

  @doc """
  Subscribes the caller to changes of one resource, or of a whole type.

  A subscriber receives `{:github_resource_changed, change}` and re-reads the
  store — it never fetches. That is the whole point: a view rides on whichever
  writer happened to pay, and costs nothing itself. See
  `Aiur.GitHub.ResourceEvents` for the shape of `change`.
  """
  @spec subscribe(key() | resource_type() | nil) :: :ok
  defdelegate subscribe(key_or_type), to: ResourceEvents

  @doc "Unsubscribes the caller from one resource's or one type's changes."
  @spec unsubscribe(key() | resource_type() | nil) :: :ok
  defdelegate unsubscribe(key_or_type), to: ResourceEvents

  @doc "Subscribes the caller to every change of one resource type."
  @spec subscribe_type(resource_type()) :: :ok
  def subscribe_type(type) when is_atom(type), do: ResourceEvents.subscribe(type)

  @doc "Subscribes the caller to every store change."
  @spec subscribe_all() :: :ok
  defdelegate subscribe_all(), to: ResourceEvents

  @doc """
  Drops every entry.

  Test seam. The store is deliberately global and long-lived, which in a suite
  means one case's published comment can suppress an unrelated case that reuses
  the same fixture id — the same hazard `Aiur.Events.Publisher`'s dedup table
  already has, and the shared test setup clears both for the same reason.
  """
  @spec reset() :: :ok
  def reset do
    with_table(:ok, fn table ->
      :ets.delete_all_objects(table)
      :ok
    end)
  end

  @doc false
  @spec forget(key() | nil) :: :ok
  def forget(nil), do: :ok

  def forget(key) do
    with_table(:ok, fn table ->
      :ets.delete(table, key)
      :ok
    end)
  end

  @doc false
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, 15_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  True when there is a store to read and write.

  Answered from the table every read and write funnels through, not from a
  process name: writes land in ETS from the caller's own process, and the table
  name is fixed while the process name is a start-up option. A caller that gates
  on the wrong one would skip its work silently against a store that is running.
  """
  @spec running?() :: boolean()
  def running?, do: with_table(false, fn _table -> true end)

  @doc """
  How long an entry is kept, in milliseconds.

  Exposed so a reader deciding what to call stale does not restate the number.
  A view calling an entry expired while the store still holds and serves it is
  a disagreement about the same fact, and the two would drift apart silently.
  """
  @spec retention_ms() :: pos_integer()
  def retention_ms, do: @retention_ms

  @doc "Entry count, or `0` when no store is running."
  @spec size() :: non_neg_integer()
  def size do
    with_table(0, fn table -> :ets.info(table, :size) || 0 end)
  end

  # -- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])

    path = resolve_path(opts)
    loaded = load(path)

    # `insert_new/2`, not `insert/2`. The table is `:named_table` and `:public`
    # and every writer reaches it through `:ets.whereis/1`, so it is writable from
    # the instant `:ets.new/2` returns — which is before this load finishes. A
    # webhook delivery landing in that window deposits the *current* body, and a
    # blind insert of the checkpoint would replace it with whatever was on disk up
    # to 30 seconds before the restart. That is a body rollback at boot, arriving
    # through the one write path that never had a compare-and-swap.
    Enum.each(loaded, &:ets.insert_new(table, &1))

    if path, do: schedule(:checkpoint, checkpoint_interval(opts))
    schedule(:sweep, sweep_interval(opts))

    {:ok, %{table: table, path: path, last_written: nil}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {reply, state} = checkpoint(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:checkpoint, state) do
    {_reply, state} = checkpoint(state)
    schedule(:checkpoint, @checkpoint_interval_ms)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    sweep(state.table)
    schedule(:sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    checkpoint(state)
    :ok
  end

  # -- internals ------------------------------------------------------------

  defp sweep_interval(opts), do: Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
  defp checkpoint_interval(opts), do: Keyword.get(opts, :checkpoint_interval_ms, @checkpoint_interval_ms)

  defp schedule(message, interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), message, interval)
  end

  defp schedule(_message, _interval), do: :ok

  defp lookup(key) do
    with_table(nil, fn table ->
      case :ets.lookup(table, key) do
        [{^key, entry}] -> entry
        _other -> nil
      end
    end)
  end

  # Every write in the module funnels through here, which is why publication
  # lives here too: a writer that had to remember to announce would eventually
  # forget, and leave a subscribed view stale with no way to notice.
  #
  # Writes land in ETS from the caller's own process rather than through the
  # GenServer, because the poll fan-out writes one entry per comment and a single
  # mailbox would become the bottleneck this store exists to remove.
  #
  # A plain read-modify-write would not be safe at that concurrency, and the
  # danger is not the harmless one it looks like. Two writers share a key as soon
  # as one pipe deposits a body and another records a validator for the same
  # resource — `:pull_request` and `:issue` have exactly that pair of writers. A
  # `put_etag/2` that read `existing` *before* a concurrent `put_resource/3`
  # inserted the body would re-insert the entry without that body while keeping
  # the newer validator: a lost write, and specifically the bodyless-validator
  # pair this module refuses everywhere else, because the next reader then sends
  # `If-None-Match`, is told `304`, and holds nothing.
  #
  # So the modify is a compare-and-swap. `:ets.select_replace/2` only replaces
  # while the entry is still byte-for-byte the one this call read, and
  # `:ets.insert_new/2` only creates while there is still nothing there. A racing
  # writer makes this one read again and re-apply `fun`, so both writes survive.
  #
  # ## The retry budget is part of the guarantee, not a detail
  #
  # A bounded budget whose last resort is an unconditional insert is not a
  # compare-and-swap: it is a compare-and-swap with a lost update wired into its
  # exhaustion path. Measured on `:issue` with four writers doing 150 merges
  # each, contention is real (about 1.7 failed swaps per successful one) and the
  # losing writer is *not* independently unlucky — BEAM's reduction-based
  # preemption phase-locks a writer that keeps being descheduled in the same
  # window between its read and its swap, so runs of tens of consecutive
  # failures happen where independence would predict none. Every one of those
  # runs that reached the old budget of 50 blind-inserted a body derived from a
  # read that was by then dozens of generations stale: the held `"gen"` counter
  # went *backwards*, and the final count came out below the number of merges.
  # That is the exact lost update this function exists to prevent, arriving
  # through its own escape hatch. See #2128.
  #
  # So the budget still exists — an unbounded spin in a poll task is its own
  # failure — but it is spent differently and it ends differently:
  #
  #   * the first `@update_spin_attempts` retries are immediate, which is all
  #     ordinary contention ever needs;
  #   * after that each retry yields the scheduler first, which breaks the
  #     phase-lock by moving this process's reduction budget relative to its
  #     competitors;
  #   * after that each retry sleeps a randomised millisecond, which decorrelates
  #     writers outright;
  #   * and if even that budget runs out the write is **abandoned**, never
  #     forced. Abandoning costs a reader one full-price fetch, which is this
  #     module's documented fail-open direction. Forcing costs correctness: a
  #     reader served `open` for a ticket Aiur has closed.
  @update_spin_attempts 8
  @update_yield_attempts 64
  @update_backoff_attempts 128
  @update_attempts @update_spin_attempts + @update_yield_attempts + @update_backoff_attempts

  defp update(key, fun) do
    with_table(:ok, fn table ->
      {_reply, result} = update_cas(table, key, &{fun.(&1), :ok}, :ok, @update_attempts)
      result
    end)
  end

  # The reply-carrying form. `fun` answers `{entry, reply}`, so a caller whose
  # decision depends on what it found *inside* the swap can report that decision
  # without a second, racy read. `revalidate/3` is the reason it exists: whether a
  # `304` confirmed the held body or was superseded by a concurrent deposit is
  # only knowable at the instant of the compare-and-swap.
  #
  # `default` is also the answer when the write is abandoned under pathological
  # contention, for the same reason it is the answer when no table exists: an
  # abandoned write has decided nothing, so the caller must be told the
  # fail-open thing rather than a decision that never happened.
  defp update_reply(key, default, fun) do
    with_table(default, fn table ->
      {reply, _result} = update_cas(table, key, fun, default, @update_attempts)
      reply
    end)
  end

  defp update_cas(table, key, fun, abandon_reply, attempts_left) do
    existing =
      case :ets.lookup(table, key) do
        [{^key, entry}] -> entry
        _other -> nil
      end

    case fun.(existing || %{}) do
      # `fun` decided, against the entry as it stands inside the swap, that there
      # is nothing to write. Not a failed swap and not a dropped write — the
      # decision *is* the outcome, so no entry is created and nothing is
      # announced. Without this a caller that only conditionally writes has to
      # make its decision outside the swap, which is check-then-act.
      {:skip, reply} ->
        {reply, :ok}

      {entry, reply} ->
        entry = Map.put(entry, :recorded_at_ms, now_ms())

        if swapped?(table, key, existing, entry) do
          announce(key, existing || %{}, entry)
          {reply, :ok}
        else
          retry_update(table, key, fun, abandon_reply, attempts_left - 1)
        end
    end
  end

  # Budget spent. The write is dropped rather than forced: `entry` was derived
  # from a read the table has already moved past, so inserting it would roll the
  # held body back to a state no writer intends — and `entry` is deliberately not
  # touched here so that cannot be done by accident. A dropped store write costs
  # one full-price read; a forced stale one costs correctness.
  defp retry_update(_table, key, _fun, abandon_reply, attempts_left) when attempts_left <= 0 do
    Logger.error(
      "GitHub.ResourceStore abandoned a contended write for #{inspect(key)} after #{@update_attempts} attempts; " <>
        "the newer held entry is kept and this write is dropped rather than rolling the body back"
    )

    {abandon_reply, :ok}
  end

  defp retry_update(table, key, fun, abandon_reply, attempts_left) do
    pace(attempts_left)
    update_cas(table, key, fun, abandon_reply, attempts_left)
  end

  # Immediate while contention is ordinary, then progressively decorrelating. The
  # yield is what breaks a reduction-phase lock-step; the randomised sleep is the
  # backstop for a writer that is losing for a reason yielding cannot move.
  defp pace(attempts_left) when attempts_left > @update_yield_attempts + @update_backoff_attempts, do: :ok

  defp pace(attempts_left) when attempts_left > @update_backoff_attempts do
    :erlang.yield()
    :ok
  end

  defp pace(_attempts_left), do: Process.sleep(:rand.uniform(2))

  # `select_replace/2` matches on the whole stored object, so the guard pins the
  # entry this call actually read. `insert_new/2` covers the "was absent" case,
  # which `select_replace/2` cannot express.
  defp swapped?(table, key, nil, entry), do: :ets.insert_new(table, {key, entry})

  defp swapped?(table, key, existing, entry) do
    match_spec = [{{key, :"$1"}, [{:==, :"$1", {:const, existing}}], [{:const, {key, entry}}]}]
    :ets.select_replace(table, match_spec) == 1
  end

  # A write that leaves the entry's observable content unchanged is silent. Only
  # `recorded_at_ms` moved, so no subscriber could see a difference, and a sweep
  # re-recording an unchanged validator across the whole retention window would
  # otherwise trade the poll this store removes for a broadcast storm.
  defp announce(key, before, entry) do
    if observable(before) == observable(entry) do
      :ok
    else
      ResourceEvents.publish(key, entry)
    end
  end

  # `:data` is the load-bearing member. A body can arrive against an unchanged
  # validator — a first deposit for a resource whose ETag a sweep already
  # recorded — and that is precisely the write a viewer is waiting for, because
  # the held body is the only thing that decides whether a page has anything to
  # render. Comparing whole bodies is affordable: they are size-bounded, and an
  # identical body rewritten is a genuine no-op no subscriber should be woken for.
  #
  # Which pipe wrote it is *not* observable, and leaving it in was a broadcast
  # storm waiting for its first subscriber. The same unchanged issue read by the
  # ticket-detail path (`:fetch`) and by the poll (`:poll`) alternates that field
  # on every cycle while nothing a viewer renders moves at all, so every reader
  # of a quiet resource would have woken every subscriber of it, forever. A
  # subscriber that wants to know who paid reads it off the change event.
  defp observable(entry) do
    Map.take(entry, [:etag, :data, :data_version, :processed_at_ms, :version])
  end

  # A refused body leaves the entry's body exactly as it was.
  #
  # The refusal means "this arrival cannot be held", never "what you are holding
  # is wrong". Writing `nil` over a good body would destroy state the store
  # already paid for and force the next reader to buy it again — and it would do
  # that while keeping the old validator, which is the bodyless pair every other
  # path here refuses. `:fetched_at_ms` is left alone too: a deposit that stored
  # nothing has not refreshed anything, and stamping it now would tell the next
  # reader the held body is younger than it is.
  defp deposit(entry, :refused, source, version, opts) do
    apply_processed_mark(entry, source, version, opts)
  end

  defp deposit(entry, {:ok, data}, source, version, opts) do
    entry =
      entry
      |> Map.put(:data, data)
      |> Map.put(:data_version, version)
      |> Map.put(:fetched_at_ms, now_ms())
      |> Map.put(:data_source, source)
      |> deposit_etag(Map.get(entry, :data), data, Keyword.get(opts, :etag))

    apply_processed_mark(entry, source, version, opts)
  end

  # `:version` moves only alongside `:processed_at_ms`. See the moduledoc:
  # advancing it on its own would suppress a version nothing has handled.
  defp apply_processed_mark(entry, source, version, opts) do
    cond do
      not Keyword.get(opts, :processed, false) ->
        entry

      is_nil(version) ->
        # A mark with no version suppresses on identity alone, which would
        # swallow the resource's next genuine change. Refused rather than
        # honoured, and said out loud, because the caller asked for something
        # that quietly breaks the guarantee the store is built on.
        Logger.warning("GitHub.ResourceStore ignored processed: true with no version; suppression needs a version")

        entry

      true ->
        entry
        |> Map.put(:processed_at_ms, now_ms())
        |> Map.put(:version, version)
        |> Map.put(:source, source)
    end
  end

  # A validator describes one exact body, so which validator an entry may keep
  # is decided by what happened to the body.
  #
  #   * a validator supplied with the deposit describes the body arriving with
  #     it — record it.
  #   * `:derive` — the writer has no validator of its own (a webhook delivery
  #     is that writer). The store derives a content-based one from the body
  #     being deposited, so the entry is never left "body, no validator" — the
  #     state in which `etag/1` answers nothing and every strict read pays full
  #     price. Because the derived validator is content-based it always
  #     describes the body beside it, so a stale validator beside a new body
  #     (finding #9) cannot happen; and because the body-unchanged clause below
  #     comes first, a re-delivery of an unchanged body keeps whatever validator
  #     is already held — a GitHub ETag a fetch recorded keeps earning its free
  #     `304`.
  #   * no validator supplied and the body is **unchanged** — the held validator
  #     still describes it, so keeping it keeps the next read free.
  #   * no validator supplied and the body **changed** — the held validator
  #     describes something the store no longer holds. Keeping it is not
  #     conservative, it is wrong: every later conditional read is then
  #     guaranteed to miss, so the entry can never earn a `304` again. A webhook
  #     delivery is exactly this case — it carries a fresh body and no validator
  #     of any kind.
  #   * no body at all — nothing to describe either way, so the held validator
  #     stands and only `change_validator/1` will hand it out.
  defp deposit_etag(entry, _previous, nil, :derive), do: entry
  defp deposit_etag(entry, previous, data, :derive) when previous == data, do: entry
  defp deposit_etag(entry, _previous, data, :derive), do: Map.put(entry, :etag, derived_etag(data))

  defp deposit_etag(entry, _previous, _data, etag) when is_binary(etag) and etag != "", do: Map.put(entry, :etag, etag)

  defp deposit_etag(entry, _previous, nil, _etag), do: entry

  defp deposit_etag(entry, previous, data, _etag) when previous == data, do: entry

  defp deposit_etag(entry, _previous, _data, _etag), do: Map.delete(entry, :etag)

  # A content-based validator for a deposited body. Deterministic — the same
  # body yields the same validator — and specific to the body, so it can never
  # describe a different one. It is not a GitHub ETag: GitHub answers such a
  # validator with `200`, so its role is to keep the entry revalidatable (the
  # `etag/1` contract) rather than to replace the real ETag a fetch records.
  defp derived_etag(data) do
    case Jason.encode(data) do
      {:ok, json} -> ~s("sha256-#{Base.encode16(:crypto.hash(:sha256, json))}")
      _error -> nil
    end
  end

  # What the store will hold as a body, decided once, at deposit time, against
  # exactly what the checkpoint can write back unchanged.
  #
  # A body that survives a restart in a *different shape* than it went in is
  # worse than no body: a consumer matching `%{id: id}` would work all day and
  # raise after the next restart, with nothing to attribute it to. GitHub REST
  # bodies are string-keyed JSON, so nothing legitimate is refused here — but
  # `put_resource/3` is a public writer and the units building on this store
  # deposit arbitrary bodies, so the refusal is explicit and loud rather than a
  # comment promising it cannot happen.
  #
  # Refused: an oversized body (paid for on every checkpoint) and a body JSON
  # cannot round-trip identically — an atom-keyed map, an atom, a tuple, a
  # struct, a pid. Refusing yields `nil`, so `deposit_etag/3` also declines the
  # validator and the next reader gets an unconditional `200` with a real body
  # instead of a `304` and nothing.
  # `:refused` and `{:ok, nil}` are kept apart deliberately. "I could not hold
  # what you sent" and "I am holding nothing" are different instructions to
  # `deposit/5`: the first must leave a good held body untouched, the second is a
  # caller depositing an empty answer.
  defp storable_data(_key, nil), do: {:ok, nil}

  defp storable_data(key, data) do
    cond do
      not json_round_trips?(data) ->
        Logger.error(
          "GitHub.ResourceStore refused a body for #{inspect(key)} that JSON cannot round-trip unchanged; " <>
            "deposit string-keyed JSON data or the entry would change shape across a restart"
        )

        :refused

      oversized?(data) ->
        Logger.warning("GitHub.ResourceStore refused an oversized body for #{inspect(key)}; any previously held body is kept")

        :refused

      true ->
        {:ok, data}
    end
  end

  # Only these shapes come back from `Jason.decode/1` identical to what went in.
  # A map is admitted solely when every key is a string, because that is the one
  # difference the checkpoint cannot preserve and cannot detect afterwards.
  defp json_round_trips?(data) when is_binary(data) or is_number(data) or is_boolean(data) or is_nil(data), do: true
  defp json_round_trips?(data) when is_list(data), do: Enum.all?(data, &json_round_trips?/1)
  defp json_round_trips?(%_struct{}), do: false

  defp json_round_trips?(data) when is_map(data) do
    Enum.all?(data, fn {key, value} -> is_binary(key) and json_round_trips?(value) end)
  end

  defp json_round_trips?(_data), do: false

  # Measured as the JSON the checkpoint would have to write, for two reasons: it
  # is the size that actually costs something, and a body JSON cannot encode —
  # a tuple, a pid, a struct with no encoder — is refused here rather than
  # discovered later by a checkpoint that cannot render it.
  defp oversized?(data) do
    case Jason.encode(data) do
      {:ok, encoded} -> byte_size(encoded) > @max_data_bytes
      _error -> true
    end
  rescue
    _error -> true
  end

  # Every read and write funnels through here so a missing table — no store
  # started, a store that crashed, a test that never booted one — is answered
  # with the caller's storeless default instead of raising into a poll task.
  defp with_table(default, fun) do
    case :ets.whereis(@table) do
      :undefined -> default
      table -> fun.(table)
    end
  rescue
    ArgumentError -> default
  end

  defp now_ms, do: System.system_time(:millisecond)

  # Only ever reached with an integer: `processed?/1` guards on `is_integer/1`
  # before asking, so a second catch-all clause here would be unreachable.
  defp expired?(at) when is_integer(at), do: now_ms() - at > @retention_ms

  # A versioned mark rides the retention window; an identity-only mark rides the
  # much tighter bound, because nothing but the clock can ever release it.
  defp within_suppression_bound?(at, nil), do: now_ms() - at <= @unversioned_suppression_ms
  defp within_suppression_bound?(at, _version), do: not expired?(at)

  # Expiry and eviction are writes like any other, so neither is allowed to be a
  # check-then-act. A `foldl` that collects keys and a later `:ets.delete/2` for
  # each are two operations, and a writer depositing a fresh body in the gap has
  # its entry deleted on the strength of a `recorded_at_ms` that is no longer
  # there — the store then answers `:miss` for a resource it was just handed, and
  # the next reader pays for it again. Both deletions are therefore conditional on
  # the entry still being the one the decision was made about.
  defp sweep(table) do
    cutoff = now_ms() - @retention_ms

    # One atomic operation per object: the guard is re-evaluated against the entry
    # as it stands at the instant of deletion, so an entry a writer refreshed in
    # the meantime no longer matches and survives.
    :ets.select_delete(table, [
      {{:_, %{recorded_at_ms: :"$1"}}, [{:<, :"$1", cutoff}], [true]}
    ])

    # A hard backstop far above real volume. Crossing it means the retention
    # window alone is not bounding the set, so drop the oldest rather than let
    # the daemon's memory follow GitHub traffic without limit.
    overflow = (:ets.info(table, :size) || 0) - @max_entries

    if overflow > 0 do
      Logger.warning("GitHub.ResourceStore exceeded #{@max_entries} entries; evicting #{overflow} oldest")

      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_key, entry} -> Map.get(entry, :recorded_at_ms, 0) end)
      |> Enum.take(overflow)
      # Pinned to the exact object that was sorted, so a concurrent write between
      # the snapshot and the eviction spares the entry rather than losing it.
      |> Enum.each(fn {key, entry} -> :ets.select_delete(table, [{{key, :"$1"}, [{:==, :"$1", {:const, entry}}], [true]}]) end)
    end

    :ok
  end

  # Writes land in ETS directly from the poll fan-out rather than through this
  # process, so there is no dirty flag to trust: the checkpoint compares the
  # rendered document against the last one written and skips an identical one.
  # That keeps a steady-state cycle — the case this whole change exists to make
  # free — from also becoming a disk write every 30 seconds.
  defp checkpoint(%{path: nil} = state), do: {:ok, state}

  defp checkpoint(%{table: table, path: path} = state) do
    document = table |> :ets.tab2list() |> Enum.reduce(%{}, &encode_entry/2)

    if document == state.last_written do
      {:ok, state}
    else
      case write(path, document) do
        :ok ->
          {:ok, %{state | last_written: document}}

        {:error, reason} = error ->
          Logger.warning("GitHub.ResourceStore checkpoint failed; reason=#{inspect(reason)}")
          {error, state}
      end
    end
  end

  defp write(path, document) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(%{"version" => 1, "entries" => document}) do
      Fs.atomic_write(path, encoded, fsync: true, mode: 0o600)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode_entry({key, entry}, acc) do
    case encode_key(key) do
      nil ->
        # Loud, because this is the one place an entry can be lost with nothing
        # else to show for it: a key the checkpoint cannot render is simply
        # absent after the next restart. Naming it here is what makes the
        # disappearance attributable instead of a mystery.
        Logger.error("GitHub.ResourceStore cannot checkpoint key #{inspect(key)}; it will not survive a restart")

        acc

      encoded ->
        Map.put(acc, encoded, encode_fields(key, entry))
    end
  end

  # The same invariant `deposit_etag/3` enforces at deposit time, enforced again
  # here, because this is the other place the pair can come apart: an entry can
  # be consistent in memory and still be checkpointed as a validator whose body
  # the encoder dropped. The next boot then holds a validator with nothing behind
  # it, sends `If-None-Match`, is answered `304`, and has no data — a spent
  # request that returns nothing, which is the exact failure this store exists to
  # remove. Dropping the validator instead costs one full-price read.
  #
  # Loud for the same reason a bad key is loud: unlike a refused deposit, this
  # loss happens with no caller present to see it.
  defp encode_fields(key, entry) do
    encoded_data = entry |> Map.get(:data) |> encode_data()

    etag =
      if is_nil(encoded_data) and not is_nil(Map.get(entry, :data)) do
        Logger.error(
          "GitHub.ResourceStore cannot checkpoint the body for #{inspect(key)}; " <>
            "dropping its validator too rather than persisting a validator with no body"
        )

        nil
      else
        Map.get(entry, :etag)
      end

    %{
      "etag" => etag,
      "processed_at_ms" => Map.get(entry, :processed_at_ms),
      "version" => Map.get(entry, :version),
      "source" => entry |> Map.get(:source) |> encode_atom(),
      "recorded_at_ms" => Map.get(entry, :recorded_at_ms),
      # The body is checkpointed too. Without it a restart keeps the validators
      # but loses every answer, and the first reader after a restart pays full
      # price for state the daemon already had — which is the cost this store
      # exists to remove.
      "data" => encoded_data,
      "data_version" => Map.get(entry, :data_version),
      "data_source" => entry |> Map.get(:data_source) |> encode_atom(),
      "fetched_at_ms" => Map.get(entry, :fetched_at_ms)
    }
  end

  defp encode_atom(nil), do: nil
  defp encode_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atom(_value), do: nil

  # Only a body JSON hands back unchanged is checkpointed. `storable_data/2`
  # already refused anything else at deposit time, so this is the second gate on
  # the same invariant rather than a different rule — and it is the gate that
  # catches a body written into the table by some future path that skipped the
  # deposit checks.
  defp encode_data(data) do
    if json_round_trips?(data), do: data, else: nil
  end

  defp decode_data(data) do
    if json_round_trips?(data), do: data, else: nil
  end

  # `|` cannot appear in a repo owner, name, or GitHub node id, so it is a safe
  # separator for a flat JSON object key.
  #
  # An unlisted type is refused here as well as in `key/4`, because a key built
  # by hand bypasses `key/4` entirely and `decode_key/1` would drop it on the way
  # back in. Refusing makes `encode_entry/2` say so out loud.
  defp encode_key({type, owner, repo, id}) when is_atom(type) and is_binary(owner) and is_binary(repo) and is_binary(id) do
    cond do
      type not in @resource_types -> nil
      String.contains?(owner <> repo <> id, "|") -> nil
      true -> "#{type}|#{owner}|#{repo}|#{id}"
    end
  end

  defp encode_key(_key), do: nil

  defp load(nil), do: []

  defp load(path) do
    case JsonStore.read(path, %{}) do
      {:ok, %{"entries" => %{} = entries}} -> decode_entries(entries)
      {:ok, _other} -> []
      {:error, reason} -> log_unreadable(path, reason)
    end
  end

  # A corrupt or unreadable checkpoint costs one cold sweep, which is exactly
  # the pre-store behavior. Refusing to boot over it would be strictly worse.
  defp log_unreadable(path, reason) do
    Logger.warning("GitHub.ResourceStore checkpoint unreadable at #{path}; starting cold reason=#{inspect(reason)}")
    []
  end

  defp decode_entries(entries) do
    cutoff = now_ms() - @retention_ms

    Enum.reduce(entries, [], fn {encoded, value}, acc ->
      with key when not is_nil(key) <- decode_key(encoded),
           %{} = entry <- decode_entry(value),
           true <- Map.get(entry, :recorded_at_ms, 0) >= cutoff do
        [{key, entry} | acc]
      else
        _other -> acc
      end
    end)
  end

  defp decode_key(encoded) when is_binary(encoded) do
    case String.split(encoded, "|") do
      [type, owner, repo, id] when type != "" and owner != "" and repo != "" and id != "" ->
        # Resolved against `@resource_types` alone, never against the wider set
        # `safe_atom/1` admits for the `:source` field: a checkpoint naming
        # `webhook` in the type slot would otherwise decode into a key no
        # `key/4` can build, which `encode_key/1` then refuses on the way back
        # out — an entry that exists only until the next checkpoint and cannot be
        # reached by any reader.
        case resource_type_atom(type) do
          nil -> nil
          atom -> {atom, owner, repo, id}
        end

      _other ->
        nil
    end
  end

  defp decode_key(_encoded), do: nil

  # A checkpoint is daemon-private, but resource types are a closed set the code
  # already defines, so an unknown one is a stale or tampered record to drop
  # rather than a new atom to create.
  defp safe_atom(value) do
    resource_type_atom(value) || known_source_atom(value)
  end

  defp resource_type_atom(value), do: Enum.find(@resource_types, &(Atom.to_string(&1) == value))

  defp known_source_atom("webhook"), do: :webhook
  defp known_source_atom("poll"), do: :poll
  defp known_source_atom("mutation"), do: :mutation
  defp known_source_atom("fetch"), do: :fetch
  defp known_source_atom(_value), do: nil

  defp decode_entry(%{} = value) do
    %{
      etag: string_or_nil(Map.get(value, "etag")),
      processed_at_ms: integer_or_nil(Map.get(value, "processed_at_ms")),
      version: string_or_nil(Map.get(value, "version")),
      source: value |> Map.get("source") |> decode_source(),
      recorded_at_ms: integer_or_nil(Map.get(value, "recorded_at_ms")) || 0,
      data: decode_data(Map.get(value, "data")),
      data_version: string_or_nil(Map.get(value, "data_version")),
      data_source: value |> Map.get("data_source") |> decode_source(),
      fetched_at_ms: integer_or_nil(Map.get(value, "fetched_at_ms"))
    }
  end

  defp decode_entry(_value), do: nil

  defp decode_source(value) when is_binary(value), do: safe_atom(value)
  defp decode_source(_value), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id) and id != "", do: id
  defp normalize_id(_id), do: nil

  # A resource with no readable version is stored as `nil`, which matches only
  # another `nil` — so such a resource keeps the pre-version behavior of being
  # suppressed on identity alone. That is the right default: it is the current
  # behavior, and inventing a version would make every re-read look like an
  # edit and republish the whole window every cycle.
  defp normalize_version(version) when is_binary(version) and version != "", do: version
  defp normalize_version(_version), do: nil

  defp resolve_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, nil} ->
        nil

      {:ok, path} when is_binary(path) ->
        path

      :error ->
        configured_path() || default_path()
    end
  end

  defp configured_path do
    case Application.get_env(:aiur, :github_resource_store_path) do
      path when is_binary(path) and path != "" -> path
      _other -> nil
    end
  end

  defp default_path do
    case Config.Paths.decision_state_dir() do
      {:ok, dir} ->
        Path.join(dir, @filename)

      {:error, reason} ->
        # No resolvable state directory means no durability, not no store: the
        # in-memory half still suppresses a duplicate inside one boot, which is
        # strictly better than the pre-store behavior it falls back to.
        Logger.debug("GitHub.ResourceStore has no state directory; running in-memory reason=#{inspect(reason)}")
        nil
    end
  end
end
