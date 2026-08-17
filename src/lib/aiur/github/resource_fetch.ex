defmodule Aiur.GitHub.ResourceFetch do
  @moduledoc """
  The one entry point for "I need this GitHub resource and do not have it".

  Every other writer into `Aiur.GitHub.ResourceStore` is free: a webhook
  delivery costs nothing, and a mutation's response was paid for by a round trip
  the caller needed anyway. This module is the only path that may *spend*, so it
  is the only place that decides whether spending is necessary.

      ResourceFetch.need(key, fetcher, freshness: {:max_age_ms, 60_000}, reason: "build order")

  The order is fixed: check the store, revalidate with `If-None-Match` when a
  validator and a body are both held, fetch otherwise, write the result back,
  and let the store publish the change. A `304` does not count against GitHub's
  primary REST rate limit, so a miss on unchanged data is free rather than
  merely cheap.

  ## Every consumer states the staleness it tolerates

  `:freshness` has no default and is **required**. That is the whole design.
  One global TTL would be a number nobody chose, and the first read that needed
  something tighter would be served stale with no way to notice. The three
  tolerances are:

    * `{:max_age_ms, ms}` — a held body younger than `ms` answers. Say what you
      can live with.
    * `:any` — a held body of any age inside the store's retention window
      answers. For a view: showing something slightly old beats spending, and a
      change event will re-render it for free anyway.
    * `:strict` — the store is **not read at all**. Upstream is always
      contacted. For a decision that must not be wrong.

  ## `:strict` is a bypass, not a hint

  A strict read never consults the held body to answer. It may still send
  `If-None-Match`, because a `304` is GitHub asserting *right now* that the
  resource has not changed — that is a fresh answer, obtained for free, not a
  cached one. What it must never do is answer without asking, and it does not:
  the fetcher is invoked on every strict call.

  Reads that must be strict, because being wrong is not recoverable by waiting:

    * **merge decisions** — mergeability, approval state, review threads
    * **CI verdicts** — check runs and statuses that decide pass or fail
    * **dispatch gating** — labels, issue state and dependencies that decide
      whether an agent may start

  ## Failing open

  A cold, corrupt, absent or crashed store degrades to the pre-store behaviour:
  `ResourceStore` answers every read with the storeless default, so this module
  simply fetches, exactly as the call site did before. A read never fails
  because the cache failed. An *upstream* failure is still a failure and is
  returned — serving a stale body under a caller's declared tolerance would be
  the silent staleness this module exists to prevent.

  ## Coalescing is not here

  Two consumers racing on one cold resource both fetch. Collapsing that needs
  the budget broker's lease machinery and belongs with the agent read path; a
  private lock here would be a second mechanism for the same job.
  """

  require Logger

  alias Aiur.GitHub.ResourceStore

  @type freshness :: :strict | :any | {:max_age_ms, pos_integer()}

  @type outcome :: :store | :revalidated | :fetched

  @type meta :: %{
          outcome: outcome(),
          version: String.t() | nil,
          fetched_at_ms: integer() | nil,
          etag: String.t() | nil,
          spent?: boolean()
        }

  @type fetch_result ::
          {:ok, term()}
          | {:ok, term(), String.t() | nil}
          | {:not_modified, String.t() | nil}
          | {:error, term()}

  @type fetcher :: (keyword() -> fetch_result())

  @doc """
  Resolves `key`, spending at most one upstream request.

  `fetcher` receives `[etag: etag_or_nil]` and answers `{:ok, data}`,
  `{:ok, data, etag}`, `{:not_modified, etag}` or `{:error, reason}`. It is
  handed a validator only when the store holds the matching body, because a
  `304` without a body to serve is a spent request that returns nothing — the
  exact waste this path exists to remove.

  Options:

    * `:freshness` — **required**. See the moduledoc.
    * `:source` — the writer recorded on the entry. Defaults to `:fetch`.
    * `:version_fun` — extracts the resource's own mutation marker from the
      body. Defaults to reading `"updated_at"` from a map, `nil` otherwise.
    * `:reason` — a short human name for the consumer, logged so a spend can be
      attributed to whoever needed it.

  Answers `{:ok, data, meta}` or `{:error, reason}`. `meta.outcome` names where
  the answer came from and `meta.spent?` is false for a `:store` hit and for a
  revalidated `304`, which is what the acceptance criteria assert against.
  """
  @spec need(ResourceStore.key() | nil, fetcher(), keyword()) :: {:ok, term(), meta()} | {:error, term()}
  def need(key, fetcher, opts) when is_function(fetcher, 1) and is_list(opts) do
    freshness = required_freshness(opts)

    case held(key, freshness) do
      {:ok, entry} ->
        {:ok, entry.data,
         %{
           outcome: :store,
           version: entry.version,
           fetched_at_ms: entry.fetched_at_ms,
           etag: entry.etag,
           spent?: false
         }}

      :miss ->
        upstream(key, fetcher, opts)
    end
  end

  @doc """
  The tolerance a decision path must use.

  Exists so a merge, CI or dispatch call site reads as a declaration rather than
  as a magic atom, and so a future change to what "must not be stale" means
  lands in one place instead of being missed at one call site out of nine.
  """
  @spec decision() :: freshness()
  def decision, do: :strict

  # -- internals ------------------------------------------------------------

  # Required rather than defaulted, and raised rather than assumed, because the
  # failure mode of a guessed tolerance is a wrong decision nobody can attribute
  # later. A missing tolerance is a contract violation in Aiur's own code, caught
  # by the first call.
  defp required_freshness(opts) do
    case Keyword.fetch(opts, :freshness) do
      {:ok, :strict} -> :strict
      {:ok, :any} -> :any
      {:ok, {:max_age_ms, ms}} when is_integer(ms) and ms >= 0 -> {:max_age_ms, ms}
      {:ok, other} -> raise ArgumentError, "unknown ResourceFetch freshness #{inspect(other)}"
      :error -> raise ArgumentError, "ResourceFetch.need/3 requires :freshness; state the staleness this consumer tolerates"
    end
  end

  # A strict read does not look. Not "looks and usually ignores" — the store is
  # never consulted for the answer, so no future edit here can quietly satisfy a
  # bypass from cache.
  defp held(_key, :strict), do: :miss

  defp held(key, freshness) do
    case ResourceStore.fetch(key) do
      {:ok, entry} -> if fresh_enough?(entry, freshness), do: {:ok, entry}, else: :miss
      :miss -> :miss
    end
  end

  defp fresh_enough?(_entry, :any), do: true

  defp fresh_enough?(%{fetched_at_ms: at}, {:max_age_ms, ms}) when is_integer(at) do
    System.system_time(:millisecond) - at <= ms
  end

  # No recorded fetch time is no evidence of freshness, so a bounded consumer
  # declines it rather than treating unknown as new.
  defp fresh_enough?(_entry, {:max_age_ms, _ms}), do: false

  defp upstream(key, fetcher, opts) do
    validator = validator(key)

    case fetcher.(etag: validator) do
      {:ok, data, etag} ->
        store(key, data, etag, opts)

      {:ok, data} ->
        store(key, data, nil, opts)

      {:not_modified, etag} ->
        revalidated(key, etag, fetcher, opts)

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_fetch_result, other}}
    end
  end

  # A validator is offered only alongside the body it validates. `ResourceStore`
  # already refuses to record an ETag for a body it declined, but a body can also
  # outlive its usefulness by ageing out of the retention window while the
  # validator stays, and a `304` then costs a request and returns nothing.
  defp validator(key) do
    case ResourceStore.fetch(key) do
      {:ok, %{etag: etag}} when is_binary(etag) and etag != "" -> etag
      _other -> nil
    end
  end

  defp store(key, data, etag, opts) do
    version = version_of(data, opts)
    # One clock read, reported and stored, so the answer's `fetched_at_ms` is the
    # entry's rather than a few microseconds after it.
    now = System.system_time(:millisecond)

    ResourceStore.put_resource(key, data,
      source: Keyword.get(opts, :source, :fetch),
      version: version,
      etag: etag
    )

    log_spend(key, opts)

    {:ok, data,
     %{
       outcome: :fetched,
       version: version,
       fetched_at_ms: now,
       etag: etag,
       spent?: true
     }}
  end

  # GitHub said the held body is current. Re-depositing it is what makes the
  # entry count as fresh again for the next bounded consumer: nothing else can
  # move `fetched_at_ms`, and leaving it alone would make every later read
  # revalidate forever. The existing `:source` and version are carried over so
  # the deposit is observably identical and wakes no subscriber for a resource
  # that did not change.
  defp revalidated(key, etag, fetcher, opts) do
    case ResourceStore.fetch(key) do
      {:ok, entry} ->
        # The held validator is kept in preference to the one on the `304`.
        # GitHub may legally answer a conditional request with a *different*
        # validator for unchanged content — weak validators, compression variants
        # — and the store treats `:etag` as observable, so adopting it would
        # broadcast a change to every subscriber of a resource that did not
        # change. The held one just proved itself by earning this `304`.
        validator = entry.etag || etag
        now = System.system_time(:millisecond)

        ResourceStore.put_resource(key, entry.data,
          source: entry.source || Keyword.get(opts, :source, :fetch),
          version: entry.version,
          etag: validator
        )

        {:ok, entry.data,
         %{
           outcome: :revalidated,
           version: entry.version,
           fetched_at_ms: now,
           etag: validator,
           spent?: false
         }}

      :miss ->
        # A `304` with nothing to serve is the one failure this module must not
        # pass on as an answer: the request was spent and produced no data. It
        # means the fetcher carried a validator from somewhere other than the
        # store, so retry once unconditionally rather than return an empty read.
        Logger.warning(
          "GitHub.ResourceFetch got 304 with no held body for #{inspect(key)}; retrying unconditionally " <>
            "reason=#{inspect(Keyword.get(opts, :reason))}"
        )

        retry_unconditionally(key, fetcher, opts)
    end
  end

  defp retry_unconditionally(key, fetcher, opts) do
    case fetcher.(etag: nil) do
      {:ok, data, etag} -> store(key, data, etag, opts)
      {:ok, data} -> store(key, data, nil, opts)
      {:not_modified, _etag} -> {:error, :not_modified_without_body}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_fetch_result, other}}
    end
  end

  defp version_of(data, opts) do
    case Keyword.get(opts, :version_fun) do
      fun when is_function(fun, 1) -> fun.(data)
      _other -> default_version(data)
    end
  end

  defp default_version(%{"updated_at" => updated_at}) when is_binary(updated_at) and updated_at != "", do: updated_at
  defp default_version(_data), do: nil

  defp log_spend(key, opts) do
    Logger.debug(fn ->
      "GitHub.ResourceFetch spent a request for #{inspect(key)} reason=#{inspect(Keyword.get(opts, :reason))}"
    end)
  end
end
