defmodule Aiur.GitHub.ReadCache.Shapes do
  @moduledoc """
  The request kinds recognised by the daemon read cache.

  ## What is worth caching, and why the number

  The numbers are chosen against the poll cadence, not against how fresh the data
  could theoretically be. A TTL shorter than the cadence saves nothing; a TTL
  much longer than the cadence buys little more and holds staleness longer.

  | kind | ttl (polling) | ttl (webhook-backed) | why |
  | --- | --- | --- | --- |
  | `:comments` | 30 s | 1 h | Per-issue REST comment reads (`Aiur.GitHub.Comments`). A comment observed 30 s late costs one poll cycle of latency and nothing else — agents already wait longer than that between turns. |
  | `:issue_graph` | 30 s | 1 h | Build Order structure: dependency edges, pack status, linked pull requests. A stale edge delays a dispatch rather than corrupting one. |
  | `:repo_config` | 5 min | 1 h | Repository configuration used by required-check classification (`Aiur.GitHub.CiReadiness`), not a CI verdict. A webhook-backed repo earns 1 h only after a verified `push`, `branch_protection_rule`, `repository_ruleset`, or `repository` delivery has been observed; without one, it keeps the 5 min polling TTL. Matching pushes to the configured base or repository default branch retire it immediately. GitHub's merge queue still enforces required checks on the server. |
  | `:issue_timeline` | 30 s | 1 h | An issue's timeline (`/issues/{n}/timeline`, `Aiur.GitHub.DispatchAuthorization`). The single largest REST family measured in #2352 (1,000–1,800 reads/hr); a timeline answered up to one poll cycle late costs a dispatch decision latency, never a wrong verdict. |
  | `:issue` | 30 s | 1 h | A single issue (`/issues/{n}`). Mixed call sites — some already conditional, some unconditional reads — so the body cache absorbs the unconditional spend. |
  | `:pull` | 30 s | 1 h | A single pull request (`/pulls/{n}`). Row 5 of #2352 was the strongest single candidate: it was read **unconditionally with no validator**, so every repeat was pure waste rather than a cheap revalidation. The body is a *routing* source, never a merge-verdict source — see below. |

  ## The `:pull` body is a routing source, not a verdict source

  `GET /pulls/{n}` returns merge-gating state in the same body it returns the
  routing fields: `mergeable`, `mergeable_state`, `merged`, `merged_at`,
  `requested_reviewers` and `auto_merge`. The "What must never be cached"
  section refuses those on content for a reason, and that refusal does not stop
  at the parent resource. A reader of a cached `:pull` body must never take a
  merge decision from it: a verdict is answered only by the GraphQL selections
  `@unsafe_selections` refuses, or by the dedicated REST verdict endpoints
  (`/reviews`, `/requested_reviewers`, `/merge`) which `@unsafe_rest` refuses
  on content. The `:pull` body answers "is there an open PR, and how do I reach
  it" — the head ref, title and body that route a PR-anchored comment — and
  nothing else. The row-5 TTL is a *cost* decision; the safety decision is this
  paragraph.

  The ETag path row 5 also gained is the post-expiry backstop, not the primary
  mechanism. The read-cache key is `{method, url, body}` and carries no
  validator, so inside the TTL window a repeat is served the held body (a cache
  hit) and `If-None-Match` is not sent; once the entry expires, the conditional
  read sends the validator and GitHub's `304` is the free revalidation. On a
  webhook-backed repo the window is bounded by the delivery, not the clock: a
  `pull_request` delivery retires the `:pull` entry immediately, so the routing
  decision is stale only for a missed delivery, never for one that arrived.

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

  TTL depends on repository delivery mode. Unproven and degraded repos get the
  short bucket because only the clock retires stale entries. Proven repos get
  the long bucket for ordinary issue and PR reads because deliveries invalidate
  them. Repo configuration earns the long bucket only after a verified
  config-retiring event is observed. Degradation restores the short bucket;
  one hour is four times `webhooks.silence_threshold_seconds`.

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
  `Aiur.GitHub.Listeners.Comments.Driver` is the only call site and its
  `start_async/2` refuses to start a poll while one is in flight; the 33 ticket
  numbers are interpolated into the document, so the key changes whenever the
  watched set does; and a 33-number entry is retired when *any* one of those
  tickets is written to, which the daemon does continuously. A cacheable half
  would hit approximately never.

  """

  alias Aiur.GitHub.GraphQLCost
  alias Aiur.GitHub.ReadCache.Policy

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

  @spec classify_kind(map()) :: {:cache, Policy.class()} | {:no_cache, term()}
  def classify_kind(request) do
    case Map.get(@callers, caller(request)) do
      nil -> classify_rest(request)
      class -> {:cache, class}
    end
  end

  # Branch existence, branch rules and protection, the workflow contents/state/action
  # listings, and the ruleset list/detail — the CIReadiness config surface,
  # minus the bare repository read and the candidate issue list (see above).
  # The optional query string rides along so `?ref=`/`?per_page=` URLs match.
  @repo_config_rest ~r{/repos/[^/?#]+/[^/?#]+(?:/branches/[^/?#]+(?:/protection)?|/rules/branches/[^/?#]+|/contents/\.github/workflows(?:/[^/?#]+)?|/actions/workflows|/rulesets(?:/[^/?#]+)?)(?:\?[^#]*)?$}

  # The ranked REST shapes (#2352), in the order they are matched, mapping a URL
  # to the call family it belongs to. Repository configuration is classified
  # only by the anchored `@repo_config_rest` row at the end — branch rules and protection,
  # `.github/workflows` contents, workflow lists and rulesets — never by a bare
  # `/contents/{path}` or `/branches` list. The anchored forms are the only
  # ones anyone reads, so widening to the bare prefixes would hand an hour-long
  # TTL to paths no caller owns (review #2360).
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
  # The bare `/repos/{owner}/{repo}` repository read is deliberately left to
  # the fallback: it is the auth-preflight probe, which must exercise the
  # current credential rather than be answered from a cache. The fallback is
  # not a single opaque bucket, though — a read the table cannot name is
  # refused with its route template (`GraphQLCost.route_shape/1`), the same
  # derivation `Quota` bills spend by, so the refusal report still names the
  # call family rather than folding every unrecognised read into one
  # `unclassified` total (#2357).
  defp classify_rest(%{method: :get, url: url} = request) when is_binary(url) do
    case rest_shape(url) do
      shape when shape in @cached_rest_shapes -> {:cache, shape}
      :unclassified -> {:no_cache, {:unclassified, GraphQLCost.route_shape(request)}}
      shape -> {:no_cache, {:unclassified, shape}}
    end
  end

  defp classify_rest(_request), do: {:no_cache, :unclassified}

  @doc """
  Every REST shape the classifier can name.

  This is also the bounded set the refusal metrics key on (see `Metrics`), so
  the metric map cannot grow without bound no matter what URLs arrive.
  """
  @spec shapes() :: [Policy.shape()]
  def shapes, do: @shapes

  defp rest_shape(url) do
    Enum.find_value(@rest_shapes, :unclassified, fn {regex, shape} ->
      if Regex.match?(regex, url), do: shape
    end)
  end

  defp caller(request) do
    case Map.get(request, :caller) do
      caller when is_binary(caller) -> caller
      _undeclared -> nil
    end
  end
end
