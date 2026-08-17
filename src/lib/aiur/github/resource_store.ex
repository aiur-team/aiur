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
      nothing**, and no per-resource reconciliation can recover the missing
      answer because the list-level validator suppressed the whole list.
      **Therefore every reader must treat a `304` with no held body as
      "re-read unconditionally": discard the validator and read again.**
      `Aiur.Events.GithubCommentsPoller` does exactly that; a new reader that
      does not is the way this store starts dropping data.
    * **body, no validator** — a deposit whose writer had no ETag, or a
      validator discarded by the rule above. Costs one full-price read. Always
      safe.

  A validator is never recorded for a body the store refused, at deposit time
  *or* at checkpoint time. See `deposit_etag/3` and `encode_fields/2`.

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

  ## Who writes and who reads today

  Deliberately recorded so a later unit does not assume more than exists.
  Writers: `Aiur.Events.GithubCommentsPoller` deposits each watched target's
  issue-comment and PR-conversation-comment *list* as a body with the endpoint's
  validator, and `Aiur.Events.Publisher` marks individual comment resources
  processed. Readers: the same poller serves its own `304` from the held list.
  Everything else — an agent's `gh` wrapper, the dashboard, mutation
  write-through — is still to be built on top of this, which is why the contract
  above is written down rather than left to be inferred from the one caller.

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
    # A single check run, as one `check_run` delivery reports it. Keyed on the
    # run's own id because that is the only identity one delivery can claim: it
    # says nothing about the other runs on the same head.
    :check_run,
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
    :branch_pull_request
  ]

  @type resource_type :: atom()
  @type key :: {resource_type(), String.t(), String.t(), String.t()}
  @type entry :: %{
          data: term(),
          version: String.t() | nil,
          source: atom() | nil,
          fetched_at_ms: integer() | nil,
          etag: String.t() | nil
        }

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

  @doc "The stored validator for `key`, or `nil` when there is none."
  @spec etag(key() | nil) :: String.t() | nil
  def etag(nil), do: nil

  def etag(key) do
    case lookup(key) do
      %{etag: etag} when is_binary(etag) and etag != "" -> etag
      _other -> nil
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
  duplicate is recoverable and dropping an event is not.
  """
  @spec processed?(key() | nil, String.t() | nil) :: boolean()
  def processed?(key, version \\ nil)

  def processed?(nil, _version), do: false

  def processed?(key, version) do
    case lookup(key) do
      %{processed_at_ms: at} = entry when is_integer(at) ->
        not expired?(at) and Map.get(entry, :version) == normalize_version(version)

      _other ->
        false
    end
  end

  @doc """
  Marks `key` processed by `source` (`:webhook` or `:poll`) at `version`.

  Recording the version is what lets a later edit of the same resource be told
  apart from a redelivery of it.
  """
  @spec mark_processed(key() | nil, atom(), String.t() | nil) :: :ok
  def mark_processed(key, source, version \\ nil)

  def mark_processed(nil, _source, _version), do: :ok

  def mark_processed(key, source, version) when is_atom(source) do
    update(key, fn entry ->
      entry
      |> Map.put(:processed_at_ms, now_ms())
      |> Map.put(:source, source)
      |> Map.put(:version, normalize_version(version))
    end)
  end

  @doc """
  Marks `key` processed at `version` only if it was not already.

  Returns `:marked` for the first caller and `:already_processed` for every
  later one inside the retention window, so a caller can gate a publish on the
  answer without a separate read.
  """
  @spec claim(key() | nil, atom(), String.t() | nil) :: :marked | :already_processed
  def claim(key, source, version \\ nil)

  def claim(nil, _source, _version), do: :marked

  def claim(key, source, version) when is_atom(source) do
    if processed?(key, version) do
      :already_processed
    else
      mark_processed(key, source, version)
      :marked
    end
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
    * `:etag` — a validator for a later conditional re-read.
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
  """
  @spec update_resource(key() | nil, (term() -> term()), keyword()) :: :ok
  def update_resource(key, fun, opts \\ [])

  def update_resource(nil, _fun, _opts), do: :ok

  def update_resource(key, fun, opts) when is_function(fun, 1) do
    version = normalize_version(Keyword.get(opts, :version))
    source = Keyword.get(opts, :source, :mutation)

    update(key, fn existing ->
      storable = existing |> held_body() |> fun.() |> then(&storable_data(key, &1))
      deposit(existing, storable, source, version, opts)
    end)
  end

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
    # Checked first so forgetting a validator nothing holds does not create an
    # empty entry for the key.
    if is_nil(etag(key)) do
      :ok
    else
      update(key, fn entry -> Map.delete(entry, :etag) end)
    end
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
             source: Map.get(entry, :source),
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
    Enum.each(loaded, &:ets.insert(table, &1))

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
  @update_attempts 50
  defp update(key, fun) do
    with_table(:ok, fn table -> update_cas(table, key, fun, @update_attempts) end)
  end

  defp update_cas(table, key, fun, attempts_left) do
    existing =
      case :ets.lookup(table, key) do
        [{^key, entry}] -> entry
        _other -> nil
      end

    entry = (existing || %{}) |> fun.() |> Map.put(:recorded_at_ms, now_ms())

    if swapped?(table, key, existing, entry) do
      announce(key, existing || %{}, entry)
      :ok
    else
      retry_update(table, key, fun, attempts_left - 1, entry)
    end
  end

  # The retry budget exists only so a pathological live-lock cannot spin a poll
  # task forever. Reaching it means writers are contending on one key far beyond
  # anything real, and the last resort is the pre-CAS behaviour — a blind insert
  # that may lose a concurrent field — which is still strictly better than
  # dropping this write.
  defp retry_update(table, key, _fun, 0, entry) do
    Logger.warning("GitHub.ResourceStore gave up retrying a contended write for #{inspect(key)}; inserting unconditionally")

    :ets.insert(table, {key, entry})
    announce(key, %{}, entry)
    :ok
  end

  defp retry_update(table, key, fun, attempts_left, _entry), do: update_cas(table, key, fun, attempts_left)

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
  defp observable(entry) do
    Map.take(entry, [:etag, :data, :data_version, :processed_at_ms, :source, :version])
  end

  defp deposit(entry, data, source, version, opts) do
    entry =
      entry
      |> Map.put(:data, data)
      |> Map.put(:data_version, version)
      |> Map.put(:fetched_at_ms, now_ms())
      |> Map.put(:source, source)
      |> deposit_etag(data, Keyword.get(opts, :etag))

    # `:version` moves only alongside `:processed_at_ms`. See the moduledoc:
    # advancing it on its own would suppress a version nothing has handled.
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
    end
  end

  # A validator is only recorded alongside the body it validates. Recording it
  # for a body the store refused would earn the next reader a `304` for a
  # resource nothing here holds — a spent request that returns no data, which is
  # the exact failure this store exists to remove. Keeping the older validator
  # instead guarantees a `200` with a body.
  defp deposit_etag(entry, nil, _etag), do: entry

  defp deposit_etag(entry, _data, etag) when is_binary(etag) and etag != "", do: Map.put(entry, :etag, etag)

  defp deposit_etag(entry, _data, _etag), do: entry

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
  defp storable_data(_key, nil), do: nil

  defp storable_data(key, data) do
    cond do
      not json_round_trips?(data) ->
        Logger.error(
          "GitHub.ResourceStore refused a body for #{inspect(key)} that JSON cannot round-trip unchanged; " <>
            "deposit string-keyed JSON data or the entry would change shape across a restart"
        )

        nil

      oversized?(data) ->
        Logger.debug("GitHub.ResourceStore refused an oversized body for #{inspect(key)}")
        nil

      true ->
        data
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

  defp sweep(table) do
    cutoff = now_ms() - @retention_ms

    expired =
      :ets.foldl(
        fn {key, entry}, acc ->
          if Map.get(entry, :recorded_at_ms, 0) < cutoff, do: [key | acc], else: acc
        end,
        [],
        table
      )

    Enum.each(expired, &:ets.delete(table, &1))

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
      |> Enum.each(fn {key, _entry} -> :ets.delete(table, key) end)
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
