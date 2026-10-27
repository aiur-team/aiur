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

  `Aiur.GitHub.GraphQLCost` prices every query at this chokepoint. Caching is
  placed the same way, so each read consults the cache. `Aiur.GitHub.ReadCache.Policy`
  defaults to refusing; reads still get classified, counted, and made visible.

  `Aiur.GitHub.CycleFetchCache` is a per-process, per-cycle memoizer with no TTL, opted into at each call
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

  An entry is stamped with the moment its fetch **started**, not the moment the
  response came back, and is served only when all of the following hold — the
  same test `priv/github_guard/gh/` applies to the agent-side store:

    * it was stamped no more than its TTL ago;
    * it was not stamped in the future;
    * it was stamped **after** every invalidation marker that covers it —
      `:root`, its repository, the repository's collections when the entry
      enumerates, and each issue-or-pull-request number the request named.

  The start stamp is what closes the write-after-invalidate race, and it is the
  whole of it. Markers being timestamps rather than deletions is necessary but
  not sufficient: with a return-time stamp, a read starting at T0 and landing at
  T2 buries a marker written at T1, because T1 is older than T2 and the entry
  looks newer than the news. A real GitHub read takes hundreds of milliseconds,
  so that window covers essentially every mutation the fleet makes during a poll
  cycle — the guard would have been inert exactly when it mattered. Dating the
  entry from T0 makes the marker win, which is correct on its own terms too: a
  response describes the resource as of when GitHub read it, never later than
  when the request left.

  This is also why the TTL is measured from T0. A slow read yields a shorter
  useful life, because its body was already stale when it arrived.

  ## Sharing between shapes

  The stored value is keyed by `{identities, shape}` — the resources the request
  observed, plus a digest of the exact document and variables. Two queries about
  the same pull request therefore share *invalidation* but not *bytes*, which is
  the same split `Aiur.GitHub.AgentCache` documents: replaying one shape's
  response for another shape's request would be imitation, and an imitation that
  is subtly wrong corrupts a caller without ever raising.
  """

  use GenServer

  alias Aiur.GitHub.Access.Settings
  alias Aiur.GitHub.GraphQLCost
  alias Aiur.GitHub.ReadCache.{Identity, Metrics, Policy, StoreEntries}

  @entries :aiur_github_read_cache_entries
  @markers :aiur_github_read_cache_markers
  @pr_commits :aiur_github_pr_commit_messages

  # A retention bound for the sweep, deliberately far above the TTLs `Policy`
  # hands out. It is not the maximum TTL and must not be tightened to match one:
  # `:github_read_cache_ttls` lets an operator raise a TTL at runtime, and a
  # sweep that dropped entries still inside their window would turn a config
  # change into silent cache misses. Freshness is decided on read, so sweeping
  # late costs memory and sweeping early costs points.
  #
  # `Policy` now issues hour-long TTLs to webhook-backed repos (the delivery
  # retires what it changes, so the TTL is a backstop rather than a freshness
  # guess), so the bound sits at four hours to stay well above the largest TTL
  # the cache can issue today and the largest an operator override is likely to
  # set.
  @max_ttl_ms 4 * 60 * 60_000
  @sweep_interval_ms 60_000
  @pr_commit_ttl_ms 4 * 60 * 60_000

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
    Settings.with_request(fn ->
      caller = declared_caller(request)

      case Policy.classify(request) do
        {:cache, class, ttl_ms} -> read_through(request, fetch, class, ttl_ms, caller)
        {:no_cache, :write} -> StoreEntries.write_through(request, fetch, caller)
        {:no_cache, reason} -> refuse(fetch, reason, caller)
      end
    end)
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
      Enum.each(identities, &StoreEntries.mark(&1, now))
      Metrics.invalidation(length(identities))
      :ok
    end
  end

  def invalidate(_identities), do: :ok

  @doc """
  The retention bound the sweep deletes past, in milliseconds.

  Exposed so a test can assert no class TTL reaches it: an entry deleted by the
  sweep is an entry the cache was still entitled to serve, so the bound and the
  shipped TTLs have to stay apart or the sweep turns into a silent miss
  generator.
  """
  @spec max_ttl_ms() :: pos_integer()
  def max_ttl_ms, do: @max_ttl_ms

  @doc """
  The entry ceiling at which `StoreEntries` refuses new deposits.

  Exposed so a test can assert the `:no_room` accounting without restating the
  number — the ceiling moves and the test follows it.
  """
  @spec max_entries() :: pos_integer()
  defdelegate max_entries(), to: StoreEntries

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
    with {owner, repo} <- StoreEntries.split_repo(full_name),
         parsed when is_integer(parsed) <- StoreEntries.parse_number(number) do
      invalidate([{:number, owner, repo, parsed}, {:collections, owner, repo}])
    else
      _unusable -> :ok
    end
  end

  @doc "Retires every read of a repository, for a change whose subject cannot be named."
  @spec invalidate_repo(String.t()) :: :ok
  def invalidate_repo(full_name) do
    case StoreEntries.split_repo(full_name) do
      {owner, repo} -> invalidate([{:repo, owner, repo}])
      _unusable -> :ok
    end
  end

  @doc "Retires repository configuration after a configuration-specific webhook."
  @spec invalidate_repo_config(String.t()) :: :ok
  def invalidate_repo_config(full_name) do
    case StoreEntries.split_repo(full_name) do
      {owner, repo} -> invalidate([{:repo_config, owner, repo}])
      _unusable -> :ok
    end
  end

  @doc "Retires everything held."
  @spec invalidate_all() :: :ok
  def invalidate_all, do: invalidate([:root])

  @doc "Memoizes merged PR commit messages by repository, PR number, and immutable head SHA."
  @spec pull_request_commits(String.t(), pos_integer(), String.t(), (-> term())) :: term()
  def pull_request_commits(repo, number, head_sha, fetch)
      when is_binary(repo) and is_integer(number) and number > 0 and is_binary(head_sha) and head_sha != "" and
             is_function(fetch, 0) do
    key = {String.downcase(repo), number, head_sha}

    case :global.trans({{__MODULE__, key}, self()}, fn -> cached_pull_request_commits(key, fetch) end) do
      {:aborted, _reason} -> fetch.()
      result -> result
    end
  rescue
    ArgumentError -> fetch.()
  end

  def pull_request_commits(_repo, _number, _head_sha, fetch) when is_function(fetch, 0), do: fetch.()

  defp cached_pull_request_commits(key, fetch) do
    now = now_ms()

    case :ets.lookup(@pr_commits, key) do
      [{^key, messages, fetched_at}] when now >= fetched_at and now - fetched_at < @pr_commit_ttl_ms ->
        {:ok, messages}

      _miss ->
        case fetch.() do
          {:ok, messages} = result when is_list(messages) ->
            :ets.match_delete(@pr_commits, {{elem(key, 0), elem(key, 1), :_}, :_, :_})
            true = :ets.insert(@pr_commits, {key, messages, now})
            result

          error ->
            error
        end
    end
  end

  @doc """
  What the cache holds and what it has done, for `aiur github-cost`.

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
    for table <- [@entries, @markers, @pr_commits], :ets.info(table) != :undefined, do: :ets.delete_all_objects(table)
    Metrics.reset()
    :ok
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@entries, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.new(@markers, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    :ets.new(@pr_commits, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
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
    :ets.select_delete(@pr_commits, [{{:_, :_, :"$1"}, [{:<, :"$1", now - @pr_commit_ttl_ms}], [true]}])

    {:noreply, schedule_sweep(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep(%{sweep_interval_ms: interval_ms} = state) do
    if interval_ms > 0, do: Process.send_after(self(), :sweep, interval_ms)
    state
  end

  defp read_through(request, fetch, class, ttl_ms, caller) do
    identities = Identity.extract(request)
    key = StoreEntries.entry_key(request, identities)

    case lookup(key, identities, ttl_ms) do
      {:ok, response} ->
        Metrics.hit(class, caller)
        {:ok, response}

      :miss ->
        Metrics.miss(class, caller)
        # Stamped before the fetch, not after it. A response describes the state
        # of the resource when GitHub read it, which is no later than when the
        # request left — so that is the moment the entry is evidence about.
        # Stamping the *return* instead dates the entry to a time it knows
        # nothing about, and a marker written while the fetch was in flight
        # would then read as older than the body it is meant to retire.
        # A real GitHub read takes hundreds of milliseconds, so that window is
        # every mutation the fleet makes during a poll cycle, not a rare edge.
        started_at = now_ms()
        result = fetch.()
        StoreEntries.deposit(key, result, started_at, class, caller)
        result
    end
  end

  # A REST refusal the policy could name arrives as a fixed `Policy.shape/0`
  # atom and is counted by `Metrics.refused/2`, whose key set `Policy.shapes/0`
  # bounds. One it could not name arrives as a route template string
  # (`"rest:GET /repos/:owner/:repo/labels"`); that key set is unbounded by
  # construction, so it goes to `Metrics.refused_shape/2`, which caps it.
  defp refuse(fetch, {:unclassified, shape}, caller) when is_binary(shape) do
    Metrics.refused_shape(shape, caller)
    fetch.()
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
  # reasoning about it, matching the guard the shell wrapper applies. With a
  # monotonic source that should be unreachable, which is exactly why it is kept
  # cheap and kept: it is the assertion that the clock assumption above still
  # holds, and an entry from a future that cannot happen is not one to serve.
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

  # The cache counts by caller the same way `Quota` attributes spend: the
  # declared call site, falling through to the GraphQL operation name and then
  # to the REST route shape (`GraphQLCost.derive/1`). Reading only
  # `request[:caller]` made the whole `unattributed` bucket a single asymmetry
  # — `Quota` names the same request `rest:GET /repos/...` while the cache
  # called it `unattributed` — so a REST read without a declared caller is
  # counted under its route shape, not under a bucket that hides every REST
  # call (#2357).
  defp declared_caller(request) when is_map(request), do: GraphQLCost.derive(request)
  defp declared_caller(_request), do: "unattributed"

  # Monotonic, not wall clock. Every timestamp here is compared only against
  # another timestamp from this same source — a deposit against a marker, a
  # deposit against a TTL — and never rendered or persisted, so the VM's
  # monotonic clock is the right unit and `System.system_time/1` was the wrong
  # one. Wall clock can step backwards (NTP correction, a suspend), which would
  # make a marker read as older than the deposit it must retire: the cache would
  # go on serving state a mutation had already superseded, and the invalidation
  # would look like it had run. That is the failure this whole module is built
  # to prevent, so it must not be reintroduced by the clock.
  #
  # The cache is in-memory and dies with the VM, so monotonic time never has to
  # survive a restart.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
