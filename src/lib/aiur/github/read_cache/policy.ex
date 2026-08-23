defmodule Aiur.GitHub.ReadCache.Policy do
  @moduledoc """
  How long a GitHub read may be trusted, decided per resource kind.

  ## Default-deny

  A request this module does not recognise is **not cached**. That is the whole
  safety design. `Aiur.GitHub.GraphQLCost` puts pricing at the transport
  chokepoint so "a query cannot be added without being priced"; the same
  placement here would, with a default of *cache*, mean a query cannot be added
  without being cached — including one whose staleness is unsafe, added by
  someone who never read this file. So the chokepoint guarantees only that every
  read is *classified*. An unclassified read costs points, exactly as it does
  today, and shows up in the metrics as `uncacheable` so the gap is visible
  rather than silent.

  ## What must never be cached

  A cache that serves stale CI status or stale review state is worse than a slow
  poll: the fleet would merge on a check that has since failed, or on an approval
  that has since been dismissed. Neither is recoverable by waiting. So:

    * **CI status of any kind** — `statusCheckRollup`, check runs, check suites,
      commit statuses, and the `:ci_poll_batch` document that carries them.
      A complete internal CI-context snapshot may let the daemon omit that one
      selection immediately after a webhook advances it, but this policy still
      refuses the document and agent-facing verdict cache; a CI verdict is never
      served from a TTL cache.
    * **Review state and merge gating** — `reviewDecision`, `mergeable`,
      `mergeStateStatus`, review threads, requested reviewers, the human-review
      gate's strict reads. An approval that was dismissed thirty seconds ago must
      not be able to authorise a merge.
    * **Anything written.** A mutation is never a read, and it invalidates.
    * **Anything unrecognised.**

  Those kinds are refused by *content*, not only by caller name: a document that
  selects a rollup is refused whichever call site sent it, so a new caller cannot
  acquire an unsafe TTL by not being in the table below.

  ## What is worth caching, and why the number

  The numbers are chosen against the poll cadence, not against how fresh the data
  could theoretically be. A TTL shorter than the cadence saves nothing; a TTL
  much longer than the cadence buys little more and holds staleness longer.

  | kind | ttl (polling) | ttl (webhook-backed) | why |
  | --- | --- | --- | --- |
  | `:comments` | 30 s | 1 h | Per-issue REST comment reads (`Aiur.GitHub.Comments`). A comment observed 30 s late costs one poll cycle of latency and nothing else — agents already wait longer than that between turns. |
  | `:issue_graph` | 30 s | 1 h | Build Order structure: dependency edges, pack status, linked pull requests. A stale edge delays a dispatch rather than corrupting one. |
  | `:repo_config` | 5 min | 1 h | Repository configuration, not a verdict: default-branch existence, branch protection, workflow list/state/file contents, rulesets (`Aiur.GitHub.CiReadiness`). Repo config changes rarely and never gates a merge on its own, so a five-minute polling body cache costs little; every webhook delivery retires it via the collections marker, which is what lets it ride the same long bucket as the other classes. |
  | `:issue_timeline` | 30 s | 1 h | An issue's timeline (`/issues/{n}/timeline`, `Aiur.GitHub.DispatchAuthorization`). The single largest REST family measured in #2352 (1,000–1,800 reads/hr); a timeline answered up to one poll cycle late costs a dispatch decision latency, never a wrong verdict. |
  | `:issue` | 30 s | 1 h | A single issue (`/issues/{n}`). Mixed call sites — some already conditional, some unconditional reads — so the body cache absorbs the unconditional spend. |
  | `:pull` | 30 s | 1 h | A single pull request (`/pulls/{n}`). Row 5 of #2352 was the strongest single candidate: it was read **unconditionally with no validator**, so every repeat was pure waste rather than a cheap revalidation. |

  ## The conditional rows stay refused on purpose

  The other REST families #2352 measured are **already ETag-conditional at
  their call sites** and answer `304` for free: the open-issue lists, the
  open-pull-request list, repo events and the repo-wide comment streams
  (`Transport.fetch_json_list_conditional/4`, `issues.ex:890`,
  `comments.ex:176`, `repo_events.ex:44`). Holding their bodies in this cache
  would trade that free revalidation for staleness — the same argument this
  module already makes for the repo comment streams. They are therefore refused
  (`{:no_cache, {:unclassified, :issue_list | :pull_list | :repo_events |
  :comment_stream | :pull_files}}`), **not** cached, and that is load-bearing:
  the refusal metric keys on the shape, so if a later change silently converts
  one of these free revalidations into a stale read, the shape disappears from
  the refusal report and the regression is visible. Do not "fix" them by giving
  them a TTL; the fix for an expensive conditional row is a cheaper validator,
  not a body cache.

  There are two buckets, and which one applies is decided by the repository's
  delivery mode, not by the class. A repo that is not proven webhook-backed —
  never configured, configured-but-unproven, or degraded from silence — gets
  the short bucket, because for it the TTL is the only freshness mechanism:
  nothing but the clock retires its entries. A repo proven webhook-backed gets
  the long bucket, because `Aiur.Events.GithubWebhook.Deposit` retires the
  `ReadCache` entries a delivery makes stale, so the TTL stops being a guess at
  staleness and becomes a backstop against a missed delivery. It collapses back
  to the short bucket the moment the repo degrades (silence past
  `webhooks.silence_threshold_seconds`), which is the measured bound on how
  long a missed delivery can go uncorrected. One hour is four times that bound.

  Every TTL here is an upper bound on staleness only in the absence of news. An
  invalidation retires the entry immediately, so the observed staleness for
  anything Aiur itself changes is zero.

  ## Two rows, because the rest were unreachable

  This table used to carry `:viewer`, `:org` and `:code_owners` as well. All
  three were dead on arrival and are removed rather than left to imply a saving
  that never happened:

    * `:viewer` and `:org` cannot be reached **structurally**. Identity here is
      repository-scoped (`Aiur.GitHub.ReadCache.Identity`), so `bot_identity`'s
      viewer query (variables `%{}`) and `Aiur.GitHub.Teams`' `/orgs/{org}/…`
      URL both answer `:no_identity` and refuse before any TTL is consulted.
      Anything not owned by a repository is uncacheable until identity grows a
      scope for it, and adding a row will not change that.
    * `:code_owners` was aimed at a call site that does not exist.
      `Aiur.GitHub.CodeOwners` reads no `/contents/` URL; the only caller of one
      is `Aiur.GitHub.CIReadiness` listing `.github/workflows`, which is CI
      configuration and belongs on the refused list, not on a five-minute TTL.

  `comment_poll_batch` is likewise absent from the caller table below, despite
  being the single largest GraphQL spender, and it is expected to read as
  `refused (unsafe_kind)` in the metrics permanently. That is the cache working,
  not a gap.

  There is no comment half to separate. Issue-comment bodies already moved to
  conditional REST (`Aiur.GitHub.Comments.fetch_issue_comments_conditional/2`),
  where an unchanged list answers `304` for free, and the document's only
  remaining `comments(...)` is nested inside `reviewThreads`. What is left is
  pull-request identity plus `reviewDecision` and `reviewThreads` — merge-gating
  state, refused on content, correctly and permanently.

  Splitting it would not pay even if it were splittable, so do not reach for
  that: there is no second reader to serve, because
  `Aiur.Orchestrator.CommentPolling` is the only call site and its
  `start_async/2` refuses to start a poll while one is in flight; the 33 ticket
  numbers are interpolated into the document, so the key changes whenever the
  watched set does; and a 33-number entry is retired when *any* one of those
  tickets is written to, which the daemon does continuously. A cacheable half
  would hit approximately never.

  ## A TTL must not outrun the caller's own freshness

  A cache at the transport chokepoint overrides freshness the call site thought
  it controlled, which is the one way this design can be quietly wrong.
  `Aiur.GitHub.ResourceFetch` requires an explicit `:freshness` with no default
  for exactly that reason, and nothing about a TTL chosen here reaches it.

  So the short bucket sits *below* the cadence of every caller that can reach
  it. Build Order's catalog refresh is clamped to the tracker poll interval
  (120 s by default) and its ticket detail freshness derives to 30 s at that
  interval, so a 30-s `:issue_graph` entry is only ever served to a *duplicate*
  read inside a window the caller was not going to re-poll anyway — which is
  where the duplication actually is: concurrent graph builds, the dashboard, and
  the CLI asking the same question at once.

  The long bucket overrides that freshness on purpose, and it is safe only
  because the delivery retires the entry: a 1-h `:issue_graph` entry is not a
  promise that GitHub state holds for an hour, it is a promise that the state
  will be retried the moment a delivery says it changed. A repo whose deliveries
  are unproven or degraded never gets the long bucket, so the caller's freshness
  is never overridden where the correction path is absent.

  A tracker configured to poll much faster narrows those cadences below these
  TTLs, and then even the short bucket would be serving staleness nobody asked
  for. The values are therefore overridable — set `:github_read_cache_ttls` to a
  map of `class => ms` — rather than compiled in, and lowering one is always
  safe. Reading the live cadence per request is not: it parses settings, and
  this runs on every GitHub request the daemon makes.
  """

  alias Aiur.GitHub.ReadCache.Identity
  alias Aiur.Webhooks.ModeTable

  @type class :: :comments | :issue_graph | :repo_config | :issue_timeline | :issue | :pull

  # Every REST shape the classifier can name, plus the fallback for a read it
  # cannot name at all. The set is small and fixed — this list is also the cap
  # on the refusal metrics, so a pathological URL cannot grow the metric map
  # without bound (see `shapes/0`).
  @type shape ::
          :comments
          | :repo_config
          | :issue_timeline
          | :issue_list
          | :pull_list
          | :issue
          | :pull
          | :repo_events
          | :comment_stream
          | :pull_files
          | :unclassified

  @type decision :: {:cache, class(), pos_integer()} | {:no_cache, atom() | {atom(), shape()}}

  # The short bucket, in force for any repo that is not proven webhook-backed:
  # never configured, configured-but-unproven, or degraded from silence. For
  # those repos the TTL *is* the freshness mechanism — nothing else retires
  # their entries — so it stays at the value chosen against the poll cadence
  # below. `:repo_config` is the one exception: it rides the CIReadiness
  # assessment cadence (its assessment is itself cached for an hour) rather
  # than the 30-second Build Order window, so its short value is five minutes,
  # not thirty seconds.
  #
  # `:issue_timeline`, `:issue` and `:pull` (the single-resource REST shapes
  # from #2352) ride the same 30-second short bucket as `:issue_graph`: they
  # are not verdicts, and a read answered up to one poll cycle late costs
  # latency, never a wrong merge or a stale dispatch.
  @default_ttls %{
    comments: 30_000,
    issue_graph: 30_000,
    repo_config: 300_000,
    issue_timeline: 30_000,
    issue: 30_000,
    pull: 30_000
  }

  # The long bucket, in force only for a repo proven webhook-backed. Once a
  # delivery retires what it changes (`Aiur.Events.GithubWebhook.Deposit`),
  # the TTL stops being the freshness mechanism and becomes a backstop against
  # a missed delivery — so it can move from seconds to an hour. The hour is
  # justified against the delivery-reliability bound this system already
  # measures: `webhooks.silence_threshold_seconds` (900) is how long a silent
  # repo may go before it degrades back to full polling, which collapses the
  # TTL to the short bucket. A delivery lost for longer than the threshold is
  # therefore bounded by the degradation sweep, and the TTL only has to cover
  # the window in which the miss has not yet been corroborated. One hour is
  # four times that bound, turning the four expensive GraphQL reads
  # (`build_order_catalog` above all) from a 30-second re-fetch into an
  # hourly one while leaving the correction path intact.
  #
  # `:repo_config` rides the same long bucket because every delivery also
  # retires the repository's collections — `invalidate_number/2` writes the
  # `{:collections, ...}` marker unconditionally, and a repo-config read is a
  # number-less REST read that carries exactly that identity (see `Identity`).
  # Repository configuration is also the class that changes *with* a delivery —
  # a push updates `.github/workflows`, branch protection or a ruleset — rather
  # than independently of one, so the delivery is precisely the correction path
  # the long bucket requires.
  #
  # `:issue_timeline`, `:issue` and `:pull` are numbered reads, so every
  # delivery or mutation that touches the number retires them through
  # `invalidate_number/2` — the same correction path `:issue_graph` rides — and
  # they earn the same hour.
  @webhook_backed_ttls %{
    comments: 3_600_000,
    issue_graph: 3_600_000,
    repo_config: 3_600_000,
    issue_timeline: 3_600_000,
    issue: 3_600_000,
    pull: 3_600_000
  }

  # Declared callers, keyed by the string `Transport` stamps on the request from
  # `opts[:caller]`. A caller absent from this table falls through to the REST
  # shapes below and then to a refusal, which is the default-deny above.
  #
  # `comment_poll_batch` is deliberately not here: it is refused on content, so
  # a row would claim a saving it cannot make. See the moduledoc.
  @callers %{
    "issue_dependencies" => :issue_graph,
    "issue_relationships" => :issue_graph,
    "build_order_pack_status" => :issue_graph,
    "build_order_catalog" => :issue_graph,
    "build_order_selected_root" => :issue_graph,
    "build_order_graph" => :issue_graph
  }

  # Selections whose staleness is unsafe at any TTL. Matched against the document
  # rather than the caller so the refusal cannot be bypassed by a new call site.
  @unsafe_selections ~r/statusCheckRollup|checkSuites|\bCheckRun\b|StatusContext|reviewDecision|mergeStateStatus|\bmergeable\b|reviewThreads|\blatestReviews\b|\breviews\s*\(/

  # REST paths whose staleness is unsafe, by the same argument.
  #
  # `actions` is deliberately NOT here as a bare alternative: the daemon's only
  # `/actions/` read is the workflow *list* (`/repos/o/r/actions/workflows`),
  # which is repository configuration, not a CI verdict. The verdict endpoints —
  # workflow runs and their jobs — are covered by the explicit `actions/(?:runs|jobs)`
  # alternative below, so narrowing the pattern refuses CI status while leaving
  # CI configuration cacheable (#2298).
  @unsafe_rest ~r{/(?:check-runs|check-suites|status|statuses|commits/[^/]+/status|merge|requested_reviewers|reviews|actions/(?:runs|jobs))(?:/|$|\?)}

  @doc """
  Classifies a request.

  Answers `{:cache, class, ttl_ms}` or `{:no_cache, reason}`. The reason is
  carried rather than dropped because it is the metric that tells an operator
  whether the cache is missing spend or correctly refusing it.
  """
  @spec classify(map()) :: decision()
  def classify(request) when is_map(request) do
    cond do
      Map.get(request, :method) != :get and not graphql_read?(request) -> {:no_cache, :write}
      unsafe?(request) -> {:no_cache, :unsafe_kind}
      # `Identity.extract/1` answers `[]` exactly when the repository cannot be
      # named, and this runs on every request including the ones that hit. The
      # cheaper question is asked instead of the fuller one it implies.
      Identity.repository(request) == nil -> {:no_cache, :no_identity}
      true -> classify_kind(request)
    end
  end

  def classify(_request), do: {:no_cache, :not_a_request}

  @doc "Every cacheable class, for rendering a metrics table with no gaps."
  @spec classes() :: [class()]
  def classes, do: Map.keys(@default_ttls)

  @doc "Every reason a read is refused, for the same reason."
  @spec no_cache_reasons() :: [atom()]
  def no_cache_reasons, do: [:write, :unsafe_kind, :no_identity, :unclassified, :disabled, :not_a_request]

  # A GraphQL read is an HTTP POST, so method alone cannot separate it from a
  # write. The document decides.
  defp graphql_read?(request) do
    Map.get(request, :method) == :post and
      Identity.graphql?(Map.get(request, :url, "")) and
      not Identity.mutation?(request)
  end

  defp unsafe?(request) do
    document_unsafe?(Identity.document(request)) or url_unsafe?(Map.get(request, :url))
  end

  defp document_unsafe?(document) when is_binary(document), do: Regex.match?(@unsafe_selections, document)
  defp document_unsafe?(_document), do: false

  defp url_unsafe?(url) when is_binary(url), do: Regex.match?(@unsafe_rest, url)
  defp url_unsafe?(_url), do: false

  defp classify_kind(request) do
    case Map.get(@callers, caller(request)) do
      nil -> classify_rest(request)
      class -> cache(class, request)
    end
  end

  # Branch existence, branch protection, the workflow contents/state/action
  # listings, and the ruleset list/detail — the CIReadiness config surface,
  # minus the bare repository read and the candidate issue list (see above).
  # The optional query string rides along so `?ref=`/`?per_page=` URLs match.
  @repo_config_rest ~r{/repos/[^/?#]+/[^/?#]+(?:/branches/[^/?#]+(?:/protection)?|/contents/\.github/workflows(?:/[^/?#]+)?|/actions/workflows|/rulesets(?:/[^/?#]+)?)(?:\?[^#]*)?$}

  # The ranked REST shapes (#2352), in the order they are matched, mapping a URL
  # to the call family it belongs to. The tail `(?:contents|branches|rulesets)`
  # row names the general repository-configuration reads — `/contents/{path}`
  # for any path, not only `.github/workflows` — while `@repo_config_rest`
  # above carries the anchored CIReadiness forms (`/actions/workflows`,
  # branch protection, rulesets) and the query-string boundary.
  @rest_shapes [
    # Row 1 — issue timeline (cacheable).
    {~r{/repos/[^/?#]+/[^/?#]+/issues/\d+/timeline}, :issue_timeline},
    # Row 2 — labeled open-issue list (ETag-conditional at its call sites; refused).
    {~r{/repos/[^/?#]+/[^/?#]+/issues\?.*\blabels=}, :issue_list},
    # Row 3 — open pull-request list (ETag-conditional at its call sites; refused).
    {~r{/repos/[^/?#]+/[^/?#]+/pulls\?}, :pull_list},
    # Row 4 — single issue (cacheable).
    {~r{/repos/[^/?#]+/[^/?#]+/issues/\d+(?:$|\?)}, :issue},
    # Row 5 — single pull request (cacheable).
    {~r{/repos/[^/?#]+/[^/?#]+/pulls/\d+(?:$|\?)}, :pull},
    # Row 6 — unlabeled open-issue list (ETag-conditional; refused).
    {~r{/repos/[^/?#]+/[^/?#]+/issues\?(?!.*\blabels=)}, :issue_list},
    # Row 7 — repository events (ETag-conditional; refused).
    {~r{/repos/[^/?#]+/[^/?#]+/events(?:$|\?)}, :repo_events},
    # Rows 8/9 — repo-wide comment streams (ETag-conditional; refused).
    {~r{/repos/[^/?#]+/[^/?#]+/(?:issues|pulls)/comments}, :comment_stream},
    # Row 10 — pull request changed files (refused: the URL carries no head sha,
    # so a push changes the response while the cache key does not; nothing is
    # cached that the URL cannot pin to an immutable object — #2332).
    {~r{/repos/[^/?#]+/[^/?#]+/pulls/\d+/files}, :pull_files},
    # Tail — repository configuration (cacheable): /contents, /branches, /rulesets.
    {~r{/repos/[^/?#]+/[^/?#]+/(?:contents|branches|rulesets)}, :repo_config},
    # Numbered comment reads (cacheable): /issues/{n}/comments, /pulls/{n}/comments.
    {~r{/repos/[^/?#]+/[^/?#]+/(?:issues|pulls)/\d+/comments}, :comments},
    # A bare commit read (`/commits/:sha`) is immutable per sha — a commit's
    # content cannot change while the sha is the same — so a body cache can
    # never serve a moved verdict (#2332). The sha is matched exactly (7–40 hex
    # digits), never a branch ref: a read by ref returns the head commit and is
    # highly mutable. The verdict shapes (`/commits/:sha/status`, check runs,
    # reviews, merge gating) are refused earlier, on content, by `@unsafe_rest`.
    {~r"/repos/[^/?#]+/[^/?#]+/commits/[0-9a-f]{7,40}(?:$|\?)", :comments},
    # The anchored CIReadiness config forms, including /actions/workflows.
    {@repo_config_rest, :repo_config}
  ]

  # The shapes that earn a body cache. Every other classified shape is a
  # deliberate refusal, named so the metrics can tell "spend the policy decided
  # is correct" from "the cache failed to recognise this read".
  @cached_rest_shapes [:comments, :repo_config, :issue_timeline, :issue, :pull]

  # Every shape the classifier can name, plus the fallback for a read it cannot
  # name at all. `Metrics.refused/2` keys on this set and folds anything else
  # back to `:unclassified`, so a pathological URL can never grow the refusal
  # metric map without bound.
  @shapes [
    :comments,
    :repo_config,
    :issue_timeline,
    :issue_list,
    :pull_list,
    :issue,
    :pull,
    :repo_events,
    :comment_stream,
    :pull_files,
    :unclassified
  ]

  # REST reads are classified into named shapes so `aiur github-cost` can say
  # which call family a refusal belongs to instead of folding every
  # unrecognised read into one `unclassified` total. Two decisions follow from
  # the shape:
  #
  #   * rows 1, 4 and 5 — the issue timeline, the single issue and the single
  #     pull request — are genuinely cacheable spend and get a real TTL. Row 5
  #     (`/pulls/{n}`) is the strongest candidate: it is read unconditionally
  #     with no validator at all, so every repeat is pure waste rather than a
  #     cheap revalidation.
  #   * the conditional rows — the issue/pull lists, repo events and the
  #     repo-wide comment streams — are deliberately NOT body-cached. They are
  #     already ETag-conditional at their call sites and answer `304` for free,
  #     and holding a body instead of sending `If-None-Match` would trade that
  #     free revalidation for staleness. They are still *classified* — the
  #     shape is what the refusal metric keys on — so a later change cannot
  #     silently convert a free revalidation into a stale read without the
  #     refusal disappearing from the report.
  #
  # The bare `/repos/{owner}/{repo}` repository read is deliberately left as
  # the `:unclassified` fallback: it is the auth-preflight probe, which must
  # exercise the current credential rather than be answered from a cache.
  defp classify_rest(%{method: :get, url: url} = request) when is_binary(url) do
    shape = rest_shape(url)

    if shape in @cached_rest_shapes do
      cache(shape, request)
    else
      {:no_cache, {:unclassified, shape}}
    end
  end

  defp classify_rest(_request), do: {:no_cache, :unclassified}

  @doc """
  Every REST shape the classifier can name.

  This is also the bounded set the refusal metrics key on (see `Metrics`), so
  the metric map cannot grow without bound no matter what URLs arrive.
  """
  @spec shapes() :: [shape()]
  def shapes, do: @shapes

  defp rest_shape(url) do
    Enum.find_value(@rest_shapes, :unclassified, fn {regex, shape} ->
      if Regex.match?(regex, url), do: shape
    end)
  end

  @doc """
  The TTL in force for a class, after any operator override.

  This is the short-bucket value, for a request whose repository's transport is
  unknown or not proven webhook-backed — which is also the conservative default
  when no repository is in hand. A configured value of zero or less is an
  instruction to stop caching that class, and is honoured as a refusal rather
  than clamped up to something the operator did not ask for.
  """
  @spec ttl_ms(class()) :: integer()
  def ttl_ms(class) do
    configured_override(class) || Map.fetch!(@default_ttls, class)
  end

  @doc """
  The TTL in force for a class given the transport serving the request's repo.

  A proven webhook-backed repo earns the long TTL, because every mutation path
  into the repo is now covered by a subscribed delivery or by our own write
  (`Aiur.Events.GithubWebhook.Deposit` retires what it deposits). Any polling
  transport — never configured, configured-but-unproven, or degraded from
  silence — keeps the short TTL, because for those repos the TTL is still the
  only freshness mechanism.

  An operator override (`:github_read_cache_ttls`) wins over both buckets, so
  tightening one class always works whichever transport the repo is on.
  """
  @spec ttl_ms(class(), Aiur.Webhooks.DeliveryMode.transport()) :: integer()
  def ttl_ms(class, transport) do
    configured_override(class) || mode_ttl(class, transport)
  end

  defp mode_ttl(class, :webhook), do: Map.fetch!(@webhook_backed_ttls, class)
  defp mode_ttl(class, _polling), do: Map.fetch!(@default_ttls, class)

  defp configured_override(class) do
    overrides = Application.get_env(:aiur, :github_read_cache_ttls, %{})
    configured = if is_map(overrides), do: Map.get(overrides, class), else: nil
    if is_integer(configured), do: configured, else: nil
  end

  defp cache(class, request) do
    case ttl_ms(class, transport(request)) do
      ttl_ms when ttl_ms > 0 -> {:cache, class, ttl_ms}
      _disabled -> {:no_cache, :disabled}
    end
  end

  # The transport for the repository a request observes, read from `ModeTable`
  # without a process hop. A request whose repository cannot be named has
  # already refused at `:no_identity` before this is consulted, so `nil` here
  # is a request that reached `classify_kind` with a named repo but whose
  # transport cannot be determined — which answers the conservative short TTL.
  defp transport(request) do
    case Identity.repository(request) do
      {owner, repo} -> ModeTable.transport("#{owner}/#{repo}")
      nil -> :polling
    end
  end

  defp caller(request) do
    case Map.get(request, :caller) do
      caller when is_binary(caller) -> caller
      _undeclared -> nil
    end
  end
end
