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

  alias Aiur.GitHub.ReadCache.{Identity, Shapes}
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

  # A refused REST read carries the shape it was refused as. A shape the
  # classifier *names* is one of the fixed `shape()` atoms, and the refusal
  # metric keys on it directly. A read it cannot name is not folded into a
  # single `unclassified` total: it carries its route template instead
  # (`GraphQLCost.route_shape/1` — `"rest:GET /repos/:owner/:repo/labels"`),
  # so the 5,000 reads/hr that reach the fallback stay attributable to a call
  # family. `Metrics.refused_shape/2` caps that string key set, so a
  # pathological URL still cannot grow the metric map without bound (#2357).
  @type decision ::
          {:cache, class(), pos_integer()}
          | {:no_cache, atom() | {atom(), shape() | String.t()}}

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
  # `:repo_config` rides the same long bucket but carries a separate identity
  # retired only by configuration-specific deliveries or a configured-base or
  # repository-default branch push.
  # Numbered writes and ordinary webhook traffic cannot retire this scope; the
  # TTL is the fallback for a missed configuration event.
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
      Map.get(request, :method) != :get and not graphql_read?(request) ->
        {:no_cache, :write}

      unsafe?(request) ->
        {:no_cache, :unsafe_kind}

      # `Identity.extract/1` answers `[]` exactly when the repository cannot be
      # named, and this runs on every request including the ones that hit. The
      # cheaper question is asked instead of the fuller one it implies.
      Identity.repository(request) == nil ->
        {:no_cache, :no_identity}

      true ->
        case Shapes.classify_kind(request) do
          {:cache, class} -> cache(class, request)
          refusal -> refusal
        end
    end
  end

  def classify(_request), do: {:no_cache, :not_a_request}

  @spec shapes() :: [shape()]
  defdelegate shapes(), to: Shapes

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
    case request_ttl(class, request) do
      ttl_ms when ttl_ms > 0 -> {:cache, class, ttl_ms}
      _disabled -> {:no_cache, :disabled}
    end
  end

  defp request_ttl(:repo_config, request) do
    {owner, repo} = Identity.repository(request)
    ttl_ms(:repo_config, ModeTable.repo_config_transport("#{owner}/#{repo}", transport(request)))
  end

  defp request_ttl(class, request), do: ttl_ms(class, transport(request))

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
end
