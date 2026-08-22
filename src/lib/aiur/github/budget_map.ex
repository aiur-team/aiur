defmodule Aiur.GitHub.BudgetMap do
  @moduledoc """
  The live budget map, shaped for the GitHub cache page.

  The static budget map was assembled by hand from a full source audit plus a
  one-hour ledger window. This module is the live version of the same picture,
  and its rule is the page's rule: **every number comes from local state and
  none of it justifies a GitHub call.** It reads the quota meter, the per-
  credential headroom table, the broker's admission ledger, the read cache, the
  resource store, the webhook registry and the agent-cache event files — all of
  which are byproducts of requests somebody already made.

  ## What is live and what is classified

  The *numbers* are live: points, calls, admissions, hits, misses, refusals,
  store sizes, delivery ages and agent hit rates all come from the sources the
  ticket's table names. The one thing that cannot be observed is which *cache
  layer stands in front of a call site* — whether a caller holds a
  `ResourceStore` reference and sends an ETag is a property of the code, not of
  the meter. That is encoded here as a documented static classification
  (`@reuse_hint`) refined by the live read-cache per-caller counters. Anything
  with no evidence either way is rendered `:unclassified`, never guessed: a
  caller we cannot classify being shown as *billed* would be exactly the
  confident-wrong-number failure this page refuses.

  ## The three verdicts

    * `:free` — spend that is free by nature: inbound webhooks and git traffic,
      which never touch the metered GitHub API, plus calls served from a cache
      (`ReadCache` hits cost nothing).
    * `:billed` — metered spend that is working as intended: the caller has a
      reuse path (a `ResourceStore` body, an ETag, a read-cache hit next cycle).
    * `:wasted` — spend that buys nothing next cycle: no validator, no stored
      body, no reuse. The ticket's measured example: `ci_poll_batch`,
      `comment_poll_batch` and `review_threads_unaddressed` together accounted
      for 86.8% of attributed GraphQL (#2265).

  The page draws an edge per attributed caller from the caller to its cache or
  store layer and on to the pool that pays (GraphQL pool, REST core pool, or
  "costs no quota"), weighted by live volume and coloured by verdict.

  ## Unit notes

  Admissions are **requests**, the quota ranking is **points** for GraphQL and
  **calls** for core, and the broker books GraphQL-on-the-wire agent commands
  into `pulls`/`issues`/`search`/`actions` families that are counted as core
  until #2297. The page states those differences beside the numbers rather than
  pretending the two views are one ledger.
  """

  alias Aiur.Config
  alias Aiur.GitHub.{BudgetLedger, CacheInspector, CredentialSelector, Quota, QuotaUsage, ReadCache, ResourceStore}
  alias Aiur.Webhooks
  alias Aiur.Webhooks.ModePresenter
  alias Aiur.Workspace.Layout

  @resources ["graphql", "core"]

  # Callers whose spend buys no reuse: no ResourceStore body, no ETag, no
  # cache to serve the next cycle. Named from the measured static version
  # (#2265) — these are the edges the page exists to surface. The list is a
  # source-level fact, kept here so the page does not have to re-audit it by
  # hand. It is authoritative for these three callers: a live read-cache
  # counter would be a signal worth reading the source about, not an automatic
  # upgrade, and a caller outside all three lists renders `:unclassified`
  # rather than being guessed either way. Kept as a plain list rather than a
  # `MapSet`: a `MapSet` return leaks the concrete set type through dialyzer's
  # opaque boundary (`contract_with_opaque`), and every consumer here just
  # enumerates the names.
  @wasted_callers ["ci_poll_batch", "comment_poll_batch", "review_threads_unaddressed"]

  # Callers free by nature: their reads arrive without a metered call.
  @free_by_nature %{
    # Resolved by the webhook receiver, not by a poll.
    "webhook_review_thread" => :webhook,
    # Agent `gh` reads served by the agent-side cache carry no admission at
    # all; the family mis-bucketing caveat (#2297) applies to the ones that do.
    "agent-shell:gh" => :git
  }

  # Callers known to hold a ResourceStore reference and/or a conditional-read
  # validator, so their metered spend leaves a body or an ETag behind for the
  # next cycle. Anything absent from both this map and `@wasted_callers` and
  # `@free_by_nature` renders `:unclassified`.
  @reuse_hint %{
    "issue_relationships" => %{store?: true, etag?: false},
    "issue_dependencies" => %{store?: true, etag?: false},
    "review_threads_verify" => %{store?: true, etag?: false},
    "review_thread_reply" => %{store?: true, etag?: false},
    "review_thread_resolve" => %{store?: true, etag?: false},
    "review_thread_unresolve" => %{store?: true, etag?: false},
    "build_order_pack_status" => %{store?: true, etag?: false}
  }

  @type verdict :: :free | :billed | :wasted | :unclassified

  @doc "The two primary budgets, in the order the page renders them."
  @spec resources() :: [String.t()]
  def resources, do: @resources

  @doc "The static list of callers whose spend buys no reuse."
  @spec wasted_callers() :: [String.t()]
  def wasted_callers, do: @wasted_callers

  @doc """
  One snapshot of everything the budget-map section renders.

  Every field is either read from a live local source or, where the property
  is source-level, from the documented static classification above. The page
  re-reads this on the store's existing change channel — no new timer.
  """
  @spec snapshot(keyword()) :: map()
  def snapshot(opts \\ []) do
    quota = quota_snapshot(opts)
    usage = QuotaUsage.sample(quota)
    read_cache = read_cache(opts)
    callers = caller_rows(usage, opts)

    %{
      captured_at: Keyword.get(opts, :now, DateTime.utc_now()),
      credentials: identity_meters(opts),
      callers: callers,
      map: map_edges(callers),
      admissions: admissions(opts),
      read_cache: read_cache,
      resource_store: resource_store(opts),
      webhooks: webhooks(opts),
      agent_cache: agent_cache(opts)
    }
  end

  @doc "The three identity meters, per configured credential."
  @spec identity_meters(keyword()) :: [map()]
  def identity_meters(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    headroom_fun = Keyword.get(opts, :headroom_fun, &CredentialSelector.headroom/1)

    rows = safely(fn -> headroom_fun.(opts) end, [])

    Enum.map(rows, fn row ->
      %{
        id: Map.get(row, :id),
        kind: Map.get(row, :kind),
        identity: Map.get(row, :identity),
        writes?: Map.get(row, :writes?, false),
        primary?: Map.get(row, :primary?, false),
        available?: Map.get(row, :available?, false),
        token_key: Map.get(row, :token_key),
        windows: Map.get(row, :windows, %{}),
        graphql: meter(row, "graphql", now),
        core: meter(row, "core", now)
      }
    end)
  end

  @doc "The per-caller ranking across both budgets, with the read-cache overlay."
  @spec caller_rows(map() | nil, keyword()) :: [map()]
  def caller_rows(usage, opts \\ []) do
    read_cache = read_cache(opts)

    usage
    |> QuotaUsage.budgets()
    |> Enum.flat_map(fn {resource, budget} ->
      budget
      |> QuotaUsage.ranked_callers()
      |> Enum.map(&caller_row(&1, resource, budget, read_cache))
    end)
    |> Enum.sort_by(&{-&1.volume, &1.caller})
  end

  @doc "The map edges: caller → cache/store layer → pool, with verdict and weight."
  @spec map_edges([map()]) :: [map()]
  def map_edges(callers) do
    Enum.map(callers, fn caller ->
      %{
        caller: caller.caller,
        resource: caller.resource,
        volume: caller.volume,
        points: caller.points,
        calls: caller.calls,
        read_cache: caller.read_cache,
        hint: caller.hint,
        pool: pool(caller),
        verdict: verdict(caller)
      }
    end)
  end

  @doc """
  The verdict for one caller row.

  `:free` when the caller is free by nature. `:wasted` when the caller is in
  the measured no-reuse set. `:billed` when the caller has a reuse path (a
  store/ETag hint or a live read-cache hit or refusal). `:unclassified` when
  there is no evidence either way — never guessed. A caller outside all three
  source-level lists is never labelled wasted on live counters alone; the
  honest answer to "does this spend buy anything next cycle?" when we have no
  data is `:unclassified`, not a confident guess.
  """
  @spec verdict(map()) :: verdict()
  def verdict(%{caller: caller} = row) do
    cond do
      Map.has_key?(@free_by_nature, caller) -> :free
      caller in @wasted_callers -> :wasted
      reuse_hint?(caller) -> :billed
      served?(row) -> :billed
      true -> :unclassified
    end
  end

  @doc "Which pool a caller's spend draws from: the GraphQL pool, the REST core pool, or nothing at all."
  @spec pool(map()) :: :graphql | :core | :free
  def pool(%{resource: resource, caller: caller}) do
    cond do
      Map.get(@free_by_nature, caller) in [:webhook, :git] -> :free
      resource == "graphql" -> :graphql
      true -> :core
    end
  end

  @doc "The broker admission ledger panel."
  @spec admissions(keyword()) :: map()
  def admissions(opts \\ []) do
    ledger_fun = Keyword.get(opts, :ledger_fun, &BudgetLedger.snapshot/1)
    ledger_fun.(opts)
  rescue
    _unavailable -> BudgetLedger.unavailable()
  catch
    :exit, _reason -> BudgetLedger.unavailable()
  end

  @doc "The read-cache panel: totals, hit rate and refusals by reason."
  @spec read_cache(keyword()) :: map()
  def read_cache(opts \\ []) do
    read_cache_fun = Keyword.get(opts, :read_cache_fun, &configured_read_cache/0)
    read_cache_fun.()
  rescue
    _unavailable -> %{available?: false, callers: %{}, refused: %{}, totals: %{}}
  catch
    :exit, _reason -> %{available?: false, callers: %{}, refused: %{}, totals: %{}}
  end

  @doc "The resource-store panel: size, retention and per-type entries."
  @spec resource_store(keyword()) :: map()
  def resource_store(opts \\ []) do
    # `get_lazy` so the projection only runs when one was not already computed —
    # the page computes it once for the whole render and threads it through, so
    # an eager default here would project the store twice per page load.
    projection = Keyword.get_lazy(opts, :projection, &CacheInspector.project/0)

    %{
      available?: ResourceStore.running?(),
      size: ResourceStore.size(),
      retention_ms: ResourceStore.retention_ms(),
      resource_types: ResourceStore.resource_types(),
      per_type:
        Enum.map(projection.groups, fn group ->
          %{
            resource_type: group.resource_type,
            label: group.label,
            count: group.count,
            bodyless: group.bodyless
          }
        end)
    }
  end

  @doc "The webhook delivery panel: one row per repo, mode and last delivery age."
  @spec webhooks(keyword()) :: [map()]
  def webhooks(opts \\ []) do
    modes_fun = Keyword.get(opts, :modes_fun, &Webhooks.list/1)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    opts
    |> Keyword.put(:modes, modes_fun.(opts))
    |> ModePresenter.rows()
    |> Enum.map(&webhook_row(&1, now))
  rescue
    _unavailable -> []
  catch
    :exit, _reason -> []
  end

  @doc "The agent-side cache panel: per workspace hit rates from `agent-cache.tsv`."
  @spec agent_cache(keyword()) :: map()
  def agent_cache(opts \\ []) do
    glob_fun = Keyword.get(opts, :agent_cache_glob_fun, &agent_cache_files/0)
    files = glob_fun.()

    workspaces = Enum.map(files, &read_workspace_cache(&1))

    %{
      available?: workspaces != [],
      workspaces: Enum.reject(workspaces, &(&1 == nil)),
      totals: aggregate_cache_totals(workspaces)
    }
  end

  @doc "The glob of `agent-cache.tsv` files under each workspace's quota state dir."
  @spec agent_cache_files() :: [Path.t()]
  def agent_cache_files do
    root = Config.workspace_root()

    root
    |> Path.expand()
    |> Layout.issue_workspace_path("__github_quota_probe__")
    |> Path.dirname()
    |> Path.join("*/.aiur-runtime/github-quota/agent-cache.tsv")
    |> Path.wildcard()
    |> Enum.sort()
  rescue
    _unavailable -> []
  catch
    :exit, _reason -> []
  end

  # -- internals ------------------------------------------------------------

  # The same provider seam the LiveView's own read-cache snapshot uses, so a
  # test can point both at one deterministic double.
  defp configured_read_cache do
    :aiur
    |> Application.get_env(:github_read_cache_provider, ReadCache)
    |> then(& &1.snapshot())
  end

  defp safely(fun, default) do
    fun.()
  rescue
    _unavailable -> default
  catch
    :exit, _reason -> default
  end

  defp quota_snapshot(opts) do
    case Keyword.fetch(opts, :quota) do
      {:ok, quota} ->
        quota

      :error ->
        server = Application.get_env(:aiur, :github_quota_server, Quota)
        Quota.snapshot(server)
    end
  rescue
    _unavailable -> %{}
  catch
    :exit, _reason -> %{}
  end

  # An observed window is a measurement; an absent one is never rendered as
  # zero. A stale meter says how stale it is: `age_seconds` is how long ago the
  # credential's own response headers were last read, recovered from the raw
  # headroom table even when the window's reset has since passed. A credential
  # whose token does not resolve on this host gets its own stale reason —
  # "unavailable" and "just not observed yet" are different facts, and an age
  # that does not exist is `nil`, never a guess.
  defp meter(row, resource, now) do
    case Map.get(row.windows, resource) do
      %{} = window ->
        %{
          state: :observed,
          used: Map.get(window, :used),
          limit: Map.get(window, :limit),
          remaining: Map.get(window, :remaining),
          reset_at: Map.get(window, :reset_at),
          observed_age_seconds: age_seconds(Map.get(window, :observed_at), now)
        }

      _none ->
        stale_meter(row, resource, now)
    end
  end

  defp stale_meter(row, resource, now) do
    age = row |> Map.get(:last_observed, %{}) |> Map.get(resource) |> last_observed_age(now)

    if Map.get(row, :available?, false) do
      %{state: :stale, reason: :no_window, age_seconds: age}
    else
      %{state: :stale, reason: :unavailable, age_seconds: nil}
    end
  end

  defp last_observed_age(%{observed_at: at}, now), do: age_seconds(at, now)
  defp last_observed_age(_none, _now), do: nil

  defp age_seconds(%DateTime{} = at, %DateTime{} = now), do: max(DateTime.diff(now, at, :second), 0)
  defp age_seconds(_at, _now), do: nil

  defp caller_row(caller, resource, _budget, read_cache) do
    points = Map.get(caller, :points, 0)
    calls = Map.get(caller, :calls, 0)

    %{
      caller: Map.get(caller, :caller),
      resource: resource,
      points: points,
      calls: calls,
      volume: if(resource == "graphql", do: points, else: calls),
      read_cache: read_cache_caller(read_cache, Map.get(caller, :caller)),
      hint: Map.get(@reuse_hint, Map.get(caller, :caller), %{})
    }
  end

  defp read_cache_caller(%{callers: callers} = _read_cache, caller) when is_map(callers) do
    case Map.fetch(callers, caller) do
      {:ok, %{} = stats} ->
        %{
          observed?: true,
          hit: Map.get(stats, :hit, 0),
          miss: Map.get(stats, :miss, 0),
          deposit: Map.get(stats, :deposit, 0),
          refused: Map.get(stats, :refused, 0)
        }

      :error ->
        %{observed?: false, hit: 0, miss: 0, deposit: 0, refused: 0}
    end
  end

  defp read_cache_caller(_read_cache, _caller),
    do: %{observed?: false, hit: 0, miss: 0, deposit: 0, refused: 0}

  # A caller with a live read-cache hit is being served free; a caller with
  # refusals is spending deliberately. Both are evidence the cache layer is in
  # front of the call, so neither can be called wasted.
  defp served?(row) do
    rc = Map.get(row, :read_cache, %{})
    Map.get(rc, :hit, 0) > 0 or Map.get(rc, :refused, 0) > 0
  end

  defp reuse_hint?(caller), do: Map.has_key?(@reuse_hint, caller)

  defp webhook_row(row, now) do
    %{
      repo: row.repo,
      transport: row.transport,
      state: row.state,
      mode_label: row.mode_label,
      reason_label: row.reason_label,
      last_delivery_at: row.last_delivery_at,
      last_delivery_age_seconds: age_seconds(row.last_delivery_at, now),
      ever_delivered?: row.ever_delivered?,
      delivery_count: row.delivery_count
    }
  end

  # Each row of an agent-cache.tsv is
  # `started_at <tab> consumer <tab> action <tab> kind <tab> id` where action is
  # `hit`, `miss`, `store` or `refused`. The file rotates to `.1` past 1 MiB, so
  # both are read and merged.
  defp read_workspace_cache(path) do
    lines = file_lines(path) ++ file_lines(path <> ".1")
    rows = Enum.map(lines, &parse_agent_cache_row/1) |> Enum.reject(&is_nil/1)
    actions = Enum.frequencies_by(rows, & &1.action)

    hit = Map.get(actions, "hit", 0)
    miss = Map.get(actions, "miss", 0)

    %{
      path: path,
      hits: hit,
      misses: miss,
      stores: Map.get(actions, "store", 0),
      refusals: Map.get(actions, "refused", 0),
      hit_rate: hit_rate(hit, miss)
    }
  end

  defp file_lines(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, _reason} -> []
    end
  end

  defp parse_agent_cache_row(line) do
    case String.split(line, "\t") do
      [started_at, _consumer, action, _kind, _id] when action in ["hit", "miss", "store", "refused"] ->
        case Integer.parse(started_at) do
          {unix, ""} -> %{started_at: unix, action: action}
          _invalid -> nil
        end

      _other ->
        nil
    end
  end

  defp hit_rate(hit, miss) when hit + miss > 0, do: Float.round(hit / (hit + miss), 4)
  defp hit_rate(_hit, _miss), do: nil

  defp aggregate_cache_totals(workspaces) do
    %{
      workspaces: length(workspaces),
      hits: Enum.sum(Enum.map(workspaces, & &1.hits)),
      misses: Enum.sum(Enum.map(workspaces, & &1.misses)),
      stores: Enum.sum(Enum.map(workspaces, & &1.stores)),
      refusals: Enum.sum(Enum.map(workspaces, & &1.refusals)),
      hit_rate: hit_rate(Enum.sum(Enum.map(workspaces, & &1.hits)), Enum.sum(Enum.map(workspaces, & &1.misses)))
    }
  end
end
