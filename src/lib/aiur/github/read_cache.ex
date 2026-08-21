defmodule Aiur.GitHub.ReadCache do
  @moduledoc """
  The daemon's read-through cache for GitHub state, at the transport chokepoint.

  ## Why a cache and not conditional requests

  The daemon spends about 12,200 GraphQL points an hour against a 5,000-point
  budget while its REST core sits near idle. The usual answer to that — send
  `If-None-Match`, get a free `304` — is unavailable: GitHub's GraphQL endpoint
  returns no `ETag` and no `Last-Modified`
  (`Aiur.BuildOrder.Cadence`, cadence.ex:73), so there is no validator to send
  and no revalidation to be had. Holding the answer is the only mechanism left
  for that budget.

  ## Why here

  `Aiur.GitHub.GraphQLCost` puts pricing at this same chokepoint, on the
  argument that "injecting at the transport chokepoint means a query cannot be
  added without being priced". Caching is placed the same way, so a read cannot
  be added without consulting the cache. Not without *being cached* — see
  `Aiur.GitHub.ReadCache.Policy`, which defaults to refusing — but without being
  classified, counted, and made visible.

  This is deliberately not the design `Aiur.GitHub.CycleFetchCache` uses. That
  one is a per-process, per-cycle memoizer with no TTL, opted into at each call
  site; it removes duplicate reads *inside* one poll cycle and cannot remove the
  same read on the next one. This removes reads across cycles and across
  processes, and no call site opts in.

  ## Reads never call this process

  The GenServer owns the tables and nothing else. Lookups, deposits and
  invalidation marks are ETS operations performed on the calling process. The
  Orchestrator issues GitHub reads inline from its poll cycle and answers
  nothing while it waits (`Transport`'s deadline note), so a cache that put a
  `GenServer.call` in front of every request would have added a second serialised
  queue in front of the one this exists to shorten.

  ## Freshness

  An entry is served only when all of the following hold, which is the same test
  `priv/github_quota_guard.sh` applies to the agent-side store:

    * it was deposited no more than its TTL ago;
    * it was not deposited in the future — a clock that moved backwards is
      treated as a miss rather than reasoned about;
    * it was deposited **after** every invalidation marker that covers it —
      `:root`, its repository, the repository's collections when the entry
      enumerates, and each issue-or-pull-request number the request named.

  Markers are timestamps, not deletions, so a marker written while a slow fetch
  is in flight still retires the entry that fetch is about to deposit. Deleting
  entries instead would leave that write-after-invalidate race open, and it is
  exactly the race that serves stale state after a mutation.

  ## Sharing between shapes

  The stored value is keyed by `{identities, shape}` — the resources the request
  observed, plus a digest of the exact document and variables. Two queries about
  the same pull request therefore share *invalidation* but not *bytes*, which is
  the same split `Aiur.GitHub.AgentCache` documents: replaying one shape's
  response for another shape's request would be imitation, and an imitation that
  is subtly wrong corrupts a caller without ever raising.
  """

  use GenServer

  alias Aiur.GitHub
  alias Aiur.GitHub.ReadCache.{Identity, Metrics, Policy}

  require Logger

  @entries :aiur_github_read_cache_entries
  @markers :aiur_github_read_cache_markers

  # A backstop, not a working limit. At the TTLs in `Policy` the live set is a
  # few hundred entries; this stops a pathological caller from making the cache
  # a memory leak.
  @max_entries 20_000

  # The longest TTL `Policy` hands out. An entry or marker older than this can
  # neither be served nor retire anything, so it is memory and nothing else.
  @max_ttl_ms 60 * 60_000
  @sweep_interval_ms 60_000

  @type identity :: Identity.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Serves `request` from cache, or runs `fetch` and deposits what it observed.

  The single entry point. `fetch` is a zero-arity function returning the
  transport's own `{:ok, response} | {:error, reason}`; a hit returns the stored
  `{:ok, response}` without calling it.

  Errors are never deposited, matching `CycleFetchCache`: an entry recording a
  failure turns one bad minute into a cached one.
  """
  @spec through(map(), (-> term())) :: term()
  def through(request, fetch) when is_function(fetch, 0) do
    caller = declared_caller(request)

    case Policy.classify(request) do
      {:cache, class, ttl_ms} -> read_through(request, fetch, class, ttl_ms, caller)
      {:no_cache, :write} -> write_through(request, fetch, caller)
      {:no_cache, reason} -> refuse(fetch, reason, caller)
    end
  end

  @doc """
  Retires every entry covering `identities`, as of now.

  Public so a webhook delivery or a mutation write-through can retire paid reads
  with a fact that arrived free — the same join `Aiur.GitHub.AgentCache` exists
  to provide for the agent-side store, pointed at the daemon's own.
  """
  @spec invalidate([identity()]) :: :ok
  def invalidate(identities) when is_list(identities) do
    identities = Enum.uniq(identities)

    if identities == [] do
      :ok
    else
      now = now_ms()
      Enum.each(identities, &mark(&1, now))
      Metrics.invalidation(length(identities))
      :ok
    end
  end

  def invalidate(_identities), do: :ok

  @doc """
  Retires every read of one issue-or-pull-request number, and the repository's
  collections with it.

  Takes a number rather than a resource type for the reason
  `AgentCache.invalidate/3` does: GitHub numbers issues and pull requests from
  one sequence, so there is no correct way to mark only one. Here that is
  structural — `Identity` has a single `:number` namespace — and the collections
  marker goes with it because a comment added to a ticket changes what a list of
  that repository's tickets answers.
  """
  @spec invalidate_number(String.t(), pos_integer() | String.t()) :: :ok
  def invalidate_number(full_name, number) do
    with {owner, repo} <- split_repo(full_name),
         parsed when is_integer(parsed) <- parse_number(number) do
      invalidate([{:number, owner, repo, parsed}, {:collections, owner, repo}])
    else
      _unusable -> :ok
    end
  end

  @doc "Retires every read of a repository, for a change whose subject cannot be named."
  @spec invalidate_repo(String.t()) :: :ok
  def invalidate_repo(full_name) do
    case split_repo(full_name) do
      {owner, repo} -> invalidate([{:repo, owner, repo}])
      _unusable -> :ok
    end
  end

  @doc "Retires everything held."
  @spec invalidate_all() :: :ok
  def invalidate_all, do: invalidate([:root])

  @doc """
  What the cache holds and what it has done, for `aiur github-cost` and the
  GitHub cache page.

  `available?` is answered before any figure, because a cache that is not
  running and a cache that is holding nothing are different facts.
  """
  @spec snapshot() :: map()
  def snapshot do
    metrics = Metrics.snapshot()

    case :ets.info(@entries, :size) do
      size when is_integer(size) ->
        Map.merge(metrics, %{
          available?: true,
          entries: size,
          markers: :ets.info(@markers, :size),
          hit_rate: Metrics.hit_rate(metrics.totals)
        })

      _unavailable ->
        Map.merge(metrics, %{available?: false, entries: nil, markers: nil, hit_rate: nil})
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    for table <- [@entries, @markers], :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    Metrics.reset()
    :ok
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@entries, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.new(@markers, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    Metrics.init()

    interval_ms = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
    {:ok, schedule_sweep(%{sweep_interval_ms: interval_ms})}
  end

  # Expiry is a freshness test on read, so a stale entry is never served whether
  # or not it has been swept. The sweep is about memory: entries whose TTL has
  # passed by a wide margin are dead weight, and so are markers older than the
  # longest TTL any entry can carry — once nothing deposited before them can
  # still be fresh, they can retire nothing.
  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()
    :ets.select_delete(@entries, [{{:_, :_, :"$1"}, [{:<, :"$1", now - @max_ttl_ms}], [true]}])
    :ets.select_delete(@markers, [{{:_, :"$1"}, [{:<, :"$1", now - @max_ttl_ms}], [true]}])

    {:noreply, schedule_sweep(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep(%{sweep_interval_ms: interval_ms} = state) do
    if interval_ms > 0, do: Process.send_after(self(), :sweep, interval_ms)
    state
  end

  defp read_through(request, fetch, class, ttl_ms, caller) do
    identities = Identity.extract(request)
    key = entry_key(request, identities)

    case lookup(key, identities, ttl_ms) do
      {:ok, response} ->
        Metrics.hit(class, caller)
        {:ok, response}

      :miss ->
        Metrics.miss(class, caller)
        result = fetch.()
        deposit(key, result, class, caller)
        result
    end
  end

  # A write is not cached and does not consult the cache. What it does is retire
  # what it changed — the free half of the design, and the reason a mutation
  # cannot leave a stale read behind it. Invalidation is stamped from *before*
  # the request, so a concurrent read that started earlier and lands later is
  # still retired.
  defp write_through(request, fetch, caller) do
    started_at = now_ms()
    result = fetch.()

    # Any HTTP response at all retires, including a 500: a write that failed
    # somewhere past the server's front door may still have applied, and
    # over-invalidating costs one re-fetch while under-invalidating serves state
    # the fleet has already changed. Only a request that never got a response —
    # `{:error, _}` from the transport — is treated as having changed nothing.
    if answered?(result) do
      identities = write_identities(request)
      Enum.each(identities, &mark(&1, started_at))
      Metrics.invalidation(length(identities))
    end

    Metrics.refused(:write, caller)
    result
  end

  # Most of Aiur's own GraphQL mutations name a node id and nothing else —
  # `addComment(subjectId:)`, `resolveReviewThread(threadId:)` — so no
  # repository can be extracted from them and, taken literally, they would
  # retire nothing at all. That is the one direction this must not fail in: a
  # write that leaves its own stale read behind is the bug the cache would be
  # blamed for. A write whose subject cannot be named therefore retires the
  # configured repository, which is the same call `Aiur.GitHub.AgentCache`
  # documents for "a change whose subject cannot be named": one re-fetch rather
  # than a stale answer for a whole window.
  defp write_identities(request) do
    case request |> Identity.extract() |> Enum.reject(&(&1 == :root)) do
      [] -> configured_repo_identity()
      identities -> identities
    end
  end

  defp configured_repo_identity do
    case GitHub.Config.repo() |> split_repo() do
      {owner, repo} -> [{:repo, owner, repo}]
      nil -> []
    end
  end

  defp refuse(fetch, reason, caller) do
    Metrics.refused(reason, caller)
    fetch.()
  end

  # A cache is not allowed to be the reason a GitHub read fails. If the tables
  # are not there — a CLI process, a restart in flight — the answer is a miss,
  # which costs the request it would have cost anyway.
  defp lookup(key, identities, ttl_ms) do
    now = now_ms()

    case :ets.lookup(@entries, key) do
      [{^key, response, deposited_at}] -> serve(response, deposited_at, now, ttl_ms, identities)
      _absent -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp serve(response, deposited_at, now, ttl_ms, identities) do
    if fresh?(deposited_at, now, ttl_ms) and not invalidated?(deposited_at, identities),
      do: {:ok, response},
      else: :miss
  end

  # `deposited_at <= now` refuses an entry stamped in the future rather than
  # reasoning about it, matching the guard the shell wrapper applies for the same
  # reason: a clock that moved is not something a cache can be correct about.
  defp fresh?(deposited_at, now, ttl_ms), do: deposited_at <= now and now - deposited_at <= ttl_ms

  # `>=` rather than `>`: a marker and a deposit that land in the same
  # millisecond must resolve as retired. The ordering between them is unknown at
  # that resolution, and the two possible mistakes are not symmetric — one costs
  # a re-fetch, the other serves state a write has already superseded.
  defp invalidated?(deposited_at, identities) do
    Enum.any?(identities, fn identity ->
      case :ets.lookup(@markers, identity) do
        [{^identity, marked_at}] -> marked_at >= deposited_at
        _unmarked -> false
      end
    end)
  rescue
    ArgumentError -> true
  end

  defp deposit(key, result, class, caller) do
    with true <- success?(result),
         {:ok, response} <- result,
         true <- room?() do
      true = :ets.insert(@entries, {key, response, now_ms()})
      Metrics.deposit(class, caller)
    else
      _skipped -> :ok
    end
  end

  # Refusing to deposit is correct at the ceiling; evicting to make room is not,
  # because the entry evicted would be chosen at random and the one that costs
  # the most points is as likely to go as any other. The sweep below drains
  # expired entries on a cadence, which is what keeps the ceiling from being
  # reached at all.
  defp room? do
    case :ets.info(@entries, :size) do
      size when is_integer(size) and size < @max_entries ->
        true

      size when is_integer(size) ->
        Logger.warning("github read cache is at its #{@max_entries}-entry ceiling (#{size}); deposits are being skipped")
        false

      _unavailable ->
        false
    end
  end

  # A GraphQL failure arrives as HTTP 200 with an `errors` key, and a *partial*
  # failure arrives as 200 with both `data` and `errors`. Neither is a
  # deposit: caching the first turns one bad minute into a cached one, and
  # caching the second holds a body with a hole in it under an identity that
  # claims to be complete. Status alone cannot tell them apart, which is why
  # the body is inspected here rather than the status trusted.
  defp success?({:ok, %{status: status, body: %{"errors" => errors}}})
       when is_integer(status) and status in 200..299 and is_list(errors) and errors != [],
       do: false

  defp success?({:ok, %{status: status}}) when is_integer(status) and status in 200..299, do: true
  defp success?(_result), do: false

  defp answered?({:ok, %{status: status}}) when is_integer(status), do: true
  defp answered?(_result), do: false

  # Identity decides invalidation; the shape decides which bytes are served. A
  # digest rather than the document itself because these documents are tens of
  # kilobytes and there is one per poll chunk.
  defp entry_key(request, identities) do
    shape =
      :crypto.hash(:sha256, :erlang.term_to_binary({Map.get(request, :method), Map.get(request, :url), Map.get(request, :body)}))

    {identities, shape}
  end

  defp mark(identity, at_ms) do
    case :ets.lookup(@markers, identity) do
      [{^identity, existing}] when existing >= at_ms -> :ok
      _older_or_absent -> :ets.insert(@markers, {identity, at_ms})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp declared_caller(request) when is_map(request) do
    case Map.get(request, :caller) do
      caller when is_binary(caller) and caller != "" -> caller
      _undeclared -> "unattributed"
    end
  end

  defp declared_caller(_request), do: "unattributed"

  defp split_repo(full_name) when is_binary(full_name) do
    case full_name |> String.downcase() |> String.split("/") do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _other -> nil
    end
  end

  defp split_repo(_full_name), do: nil

  defp parse_number(number) when is_integer(number) and number > 0, do: number

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp parse_number(_number), do: nil

  defp now_ms, do: System.system_time(:millisecond)
end
