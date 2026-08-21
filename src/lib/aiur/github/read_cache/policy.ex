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
      `Aiur.GitHub.ResourceStore` reached the same conclusion independently and
      removed `:check_run` from the store entirely when its deposit ceased
      (#2126); a CI verdict is never cached.
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

  | kind | ttl | why |
  | --- | --- | --- |
  | `:viewer` | 1 hour | The bot's own login. It changes when the credential changes, which restarts the daemon anyway. |
  | `:code_owners` | 5 min | A file in the default branch. Editing it is a pull request, so it moves on human timescales. |
  | `:org` | 5 min | Team and membership reads. Same argument. |
  | `:comments` | 30 s | The read that actually costs. A comment observed 30 s late costs one poll cycle of latency and nothing else — agents already wait longer than that between turns. |
  | `:issue_graph` | 30 s | Build Order structure: dependency edges, pack status, linked pull requests. A stale edge delays a dispatch rather than corrupting one. |

  Every TTL here is an upper bound on staleness only in the absence of news. An
  invalidation retires the entry immediately, so the observed staleness for
  anything Aiur itself changes is zero.

  ## A TTL must not outrun the caller's own freshness

  A cache at the transport chokepoint overrides freshness the call site thought
  it controlled, which is the one way this design can be quietly wrong.
  `Aiur.GitHub.ResourceFetch` requires an explicit `:freshness` with no default
  for exactly that reason, and nothing about a TTL chosen here reaches it.

  So the numbers above sit *below* the cadence of every caller that can reach
  them. Build Order's catalog refresh is clamped to the tracker poll interval
  (120 s by default) and its ticket detail freshness derives to 30 s at that
  interval, so a 30-s `:issue_graph` entry is only ever served to a *duplicate*
  read inside a window the caller was not going to re-poll anyway — which is
  where the duplication actually is: concurrent graph builds, the dashboard, and
  the CLI asking the same question at once.

  A tracker configured to poll much faster narrows those cadences below these
  TTLs, and then this table would be serving staleness nobody asked for. The
  values are therefore overridable — set `:github_read_cache_ttls` to a map of
  `class => ms` — rather than compiled in, and lowering one is always safe.
  Reading the live cadence per request is not: it parses settings, and this runs
  on every GitHub request the daemon makes.
  """

  alias Aiur.GitHub.ReadCache.Identity

  @type class :: :viewer | :code_owners | :org | :comments | :issue_graph
  @type decision :: {:cache, class(), pos_integer()} | {:no_cache, atom()}

  @minute 60_000

  @default_ttls %{viewer: 60 * @minute, code_owners: 5 * @minute, org: 5 * @minute, comments: 30_000, issue_graph: 30_000}

  # Declared callers, keyed by the string `Transport` stamps on the request from
  # `opts[:caller]`. A caller absent from this table falls through to the REST
  # shapes below and then to a refusal, which is the default-deny above.
  @callers %{
    "bot_identity" => :viewer,
    "comment_poll_batch" => :comments,
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
  @unsafe_rest ~r{/(?:check-runs|check-suites|status|statuses|commits/[^/]+/status|merge|requested_reviewers|reviews|actions)(?:/|$|\?)}

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
      class -> cache(class)
    end
  end

  defp classify_rest(%{method: :get, url: url}) when is_binary(url) do
    cond do
      String.contains?(url, "/contents/") -> cache(:code_owners)
      String.contains?(url, "/teams") -> cache(:org)
      Regex.match?(~r{/(?:issues|pulls)/\d+/comments}, url) -> cache(:comments)
      true -> {:no_cache, :unclassified}
    end
  end

  defp classify_rest(_request), do: {:no_cache, :unclassified}

  @doc """
  The TTL in force for a class, after any operator override.

  A configured value of zero or less is an instruction to stop caching that
  class, and is honoured as a refusal rather than clamped up to something the
  operator did not ask for.
  """
  @spec ttl_ms(class()) :: integer()
  def ttl_ms(class) do
    overrides = Application.get_env(:aiur, :github_read_cache_ttls, %{})
    configured = if is_map(overrides), do: Map.get(overrides, class), else: nil

    if is_integer(configured), do: configured, else: Map.fetch!(@default_ttls, class)
  end

  defp cache(class) do
    case ttl_ms(class) do
      ttl_ms when ttl_ms > 0 -> {:cache, class, ttl_ms}
      _disabled -> {:no_cache, :disabled}
    end
  end

  defp caller(request) do
    case Map.get(request, :caller) do
      caller when is_binary(caller) -> caller
      _undeclared -> nil
    end
  end
end
