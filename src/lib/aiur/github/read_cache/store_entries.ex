defmodule Aiur.GitHub.ReadCache.StoreEntries do
  @moduledoc """
  Entry deposits and write-retirement markers for the daemon read cache.

  The cache GenServer owns the public ETS tables; these operations run on the
  calling process, retaining the request-start timestamp for both reads and writes.
  """

  alias Aiur.GitHub.ReadCache.{Identity, Metrics, Outcome}

  require Logger

  @entries :aiur_github_read_cache_entries
  @markers :aiur_github_read_cache_markers

  # A backstop, not a working limit. At the TTLs in `Policy` the live set is a
  # few hundred entries; this stops a pathological caller from making the cache
  # a memory leak.
  @max_entries 20_000

  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  # A write is not cached and does not consult the cache. What it does is retire
  # what it changed — the free half of the design, and the reason a mutation
  # cannot leave a stale read behind it.
  #
  # The marker is stamped from *before* the write, and reads are stamped from
  # before their fetch, so the two are on the same footing: whichever request
  # left GitHub first is the older fact. A read that started before this write
  # is retired by it even if it lands afterwards, which is the ordering the
  # cache has to get right.
  @spec write_through(map(), (-> term()), String.t()) :: term()
  def write_through(request, fetch, caller) do
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
  # blamed for.
  #
  # A write whose subject cannot be named therefore retires `:root` —
  # everything. The obvious cheaper answer, retiring the *configured*
  # repository, is wrong rather than merely coarse: a node id says nothing
  # about which repository it belongs to, so a write against any other
  # repository would flush the configured one it did not touch and leave the
  # one it did touch stale. Guessing a repository is the failure mode; not
  # guessing is the fix.
  #
  # `cache_invalidate_writes` in the agent `gh` guard warns that retiring a repository per
  # subresource write would be "correct and ruinous" — but it is describing
  # agent workpad comments, which are rewritten every few minutes through a
  # different store. This fallback is reachable only from node-id GraphQL
  # mutations, which in this daemon means review-thread replies and
  # resolutions. Every REST write carries `/repos/{owner}/{repo}/` in its URL
  # and so never arrives here. If that ever stops being true, the metric to
  # watch is `invalidations.events` against the hit rate.
  #
  # A write that *can* name its subject retires exactly that subject, never the
  # whole repository. `Identity.extract/1` always includes `{:repo, owner, repo}`
  # — which every read of that repository also carries — so retiring it on every
  # numbered write emptied the repository's cache per mutation: on a repo the
  # daemon writes to continuously, no entry survived to be served, and the cache
  # reported 0% hits with a full, freshly-deposited table (#2372). A numbered
  # write retires the number plus the repository's collections instead — the
  # same pair `invalidate_number/2` writes for a delivery — and only a write
  # that names a repository but no number (a git ref, a repo-config write)
  # retires the repository itself.
  defp write_identities(request) do
    identities = Identity.extract(request)
    repo = Enum.find(identities, &match?({:repo, _owner, _repo}, &1))
    numbers = Enum.filter(identities, &match?({:number, _owner, _repo, _number}, &1))

    cond do
      repo == nil -> [:root]
      numbers == [] -> [repo]
      true -> [collections_identity(repo) | numbers]
    end
  end

  defp collections_identity({:repo, owner, repo}), do: {:collections, owner, repo}

  # Every miss either deposits or does not, and the not-deposited side is
  # counted with its reason so the gap between misses and deposits is
  # attributable rather than a silent subtraction. `Outcome.cacheable?/1`
  # rejects failed or partial responses while `room?/0` refuses a good
  # response only at the entry ceiling.
  @spec deposit(term(), term(), integer(), atom(), String.t()) :: :ok
  def deposit(key, result, started_at, class, caller) do
    cond do
      not Outcome.cacheable?(result, class) ->
        Metrics.not_deposited(:unsuccessful, class, caller)
        :ok

      not room?() ->
        Metrics.not_deposited(:no_room, class, caller)
        :ok

      true ->
        {:ok, response} = result
        true = :ets.insert(@entries, {key, response, started_at})
        Metrics.deposit(class, caller)
    end
  end

  # Refusing to deposit is correct at the ceiling; evicting to make room is not,
  # because the entry evicted would be chosen at random and the one that costs
  # the most points is as likely to go as any other. The cache sweep drains
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

  defp answered?({:ok, %{status: status}}) when is_integer(status), do: true
  defp answered?(_result), do: false

  # Identity decides invalidation; the shape decides which bytes are served. A
  # digest rather than the document itself because these documents are tens of
  # kilobytes and there is one per poll chunk.
  @spec entry_key(map(), [Identity.t()]) :: term()
  def entry_key(request, identities) do
    shape =
      :crypto.hash(:sha256, :erlang.term_to_binary({Map.get(request, :method), Map.get(request, :url), Map.get(request, :body)}))

    {identities, shape}
  end

  @spec mark(Identity.t(), integer()) :: :ok
  def mark(identity, at_ms) do
    case :ets.lookup(@markers, identity) do
      [{^identity, existing}] when existing >= at_ms -> :ok
      _older_or_absent -> :ets.insert(@markers, {identity, at_ms})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec split_repo(term()) :: {String.t(), String.t()} | nil
  def split_repo(full_name) when is_binary(full_name) do
    case full_name |> String.downcase() |> String.split("/") do
      [owner, repo] when owner != "" and repo != "" -> {owner, repo}
      _other -> nil
    end
  end

  def split_repo(_full_name), do: nil

  @spec parse_number(term()) :: pos_integer() | nil
  def parse_number(number) when is_integer(number) and number > 0, do: number

  def parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  def parse_number(_number), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)
end
