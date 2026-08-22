defmodule Aiur.GitHub.CacheInspector do
  @moduledoc """
  A read-only projection of the GitHub state cache, for the debug page.

  This module exists to be *proof*. The cache's central rule is that viewing
  never causes a fetch, and an inspector that could trigger one would break the
  property it was built to demonstrate. So the constraint is structural rather
  than a matter of discipline: every read here goes to a `Source`, whose whole
  contract is enumerating what is already held. There is no client, no token and
  no transport in this module's reach — not "we are careful not to fetch", but
  "there is nothing here that could".

  That is also why there is no invalidate, no eviction, no force-refresh and no
  fetch-now. Each would be one line and each would make the page unable to
  answer the question it exists to answer.

  ## Degrading

  A missing, empty or not-yet-built store is a normal state, not an error. The
  projection answers `available?: false` and an empty list, and the page says so
  in words. It never renders "0 entries" as though zero were a measurement —
  nothing cached and nothing observed are different facts and only one of them
  is good news.

  ## Elision

  A large store is truncated, and the count that was dropped is carried in the
  projection so the page can state it. Showing a subset as though it were
  everything is the specific failure this guards against: an operator who
  scrolls to the bottom of a truncated list concludes the cache does not hold
  something it does hold.

  ## Bodyless entries are counted separately

  `bodyless` is an entry holding a validator and no body. It is a sanctioned
  state — `Aiur.GitHub.ResourceStore.drop_data/1` produces it on purpose — and
  it is also the state that most easily reads as a hit when it is not one: a
  reader sending that ETag gets a `304` and no data. Counting it beside the
  totals rather than folding it into them is what makes "why did that read cost
  money" answerable from this page.
  """

  alias Aiur.GitHub.CacheInspector.{Entry, ResourceStoreSource}
  alias Aiur.GitHub.ResourceStore

  # How many rows one group page draws before it says it stopped.
  @default_limit 500

  # A hard ceiling on how many entries are classified at all. The store's own
  # backstop is 100,000 entries; building a struct for every one of them on
  # every re-render would make an open inspector expensive in exactly the way
  # this page promises not to be. Whatever is dropped here is counted and said
  # out loud rather than quietly missing.
  @projection_ceiling 5_000
  # Freshness is expressed against how long an entry may be trusted, not against
  # a number chosen when polling was five seconds apart. `stale` is the point
  # past which a consumer should say it is reading history; `expired` is the
  # retention edge, where the store itself stops keeping the entry.
  @default_stale_after_ms 5 * 60 * 1000

  # The store's own retention window, taken from the store rather than restated,
  # so a page calling an entry `expired` and a store still holding it cannot
  # drift apart.
  @default_expired_after_ms ResourceStore.retention_ms()

  # The store's own writer vocabulary, in the order the page offers it, plus the
  # bucket an unrecognised source lands in. `:other` is offered as a filter and
  # not only as a count: it is the bucket a writer nobody has taught this page
  # about shows up in, so being unable to click it is being unable to see the
  # entries most worth looking at.
  @writers [:mutation, :webhook, :fetch, :poll, :other]
  @freshness [:fresh, :stale, :expired, :unknown]

  @doc "The canonical writer buckets, in the order the page offers them."
  @spec writers() :: [atom()]
  def writers, do: @writers

  @doc "The freshness buckets, ordered from most to least trustworthy."
  @spec freshness_levels() :: [atom()]
  def freshness_levels, do: @freshness

  @doc """
  Everything the cache holds, grouped and classified.

  Takes no identity and no filter: filtering and sorting are the page's job and
  happen over this one result, because a filter that re-read the store would
  make typing in a search box cost API budget by a longer route.
  """
  @spec project(keyword()) :: map()
  def project(opts \\ []) do
    source = Keyword.get(opts, :source, configured_source())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, @default_limit)
    ceiling = Keyword.get(opts, :ceiling, @projection_ceiling)

    case read(source) do
      {:ok, raw} ->
        all = Enum.sort_by(Enum.map(raw, &Entry.new(&1, now, thresholds(opts))), &sort_key/1)
        entries = Enum.take(all, ceiling)

        %{
          available?: true,
          entries: entries,
          total: length(all),
          projected: length(entries),
          bodyless: Enum.count(all, & &1.bodyless?),
          with_body: Enum.count(all, & &1.body?),
          elided: max(length(all) - length(entries), 0),
          limit: limit,
          ceiling: ceiling,
          groups: groups(entries, limit),
          captured_at: now
        }

      :unavailable ->
        %{
          available?: false,
          entries: [],
          total: 0,
          projected: 0,
          bodyless: 0,
          with_body: 0,
          elided: 0,
          limit: limit,
          ceiling: ceiling,
          groups: [],
          captured_at: now
        }
    end
  end

  @doc """
  One entry by its stable identity, or `nil`. Never fetches on a miss.

  Searches everything the projection holds, not the slice a group page happens
  to be rendering. A deep link that resolved to "nothing is cached under this"
  because the entry fell outside a render cap would be an affirmative false
  statement on the one page whose premise is honesty about what it is showing.
  """
  @spec find(map(), String.t()) :: map() | nil
  def find(%{entries: entries}, identity) when is_binary(identity),
    do: Enum.find(entries, &(&1.identity == identity))

  def find(_projection, _identity), do: nil

  @doc """
  GitHub requests caused by somebody looking at a page.

  The headline figure on the debug page, and passive page viewing must leave it
  at zero. It counts the quota meter's observations that originated in a
  LiveView process. The quota seam records that process-scoped fact independently
  from the caller tag, so a poller containing `view` in its name cannot be billed
  to the operator and an asynchronously completed click fetch remains visible.

  The zero is only meaningful beside `observed_calls/1`. A meter that has seen
  nothing at all also reports zero here, and that is not the same fact as a busy
  meter none of whose calls came from a view — so the page prints both.
  """
  @spec view_fetches(map()) :: non_neg_integer()
  def view_fetches(%{callers: callers}) when is_list(callers) do
    Enum.reduce(callers, 0, &(view_calls(&1) + &2))
  end

  def view_fetches(_snapshot), do: 0

  @doc """
  How many GitHub calls the quota meter attributed in its current window.

  Context for `view_fetches/1`: a zero against a meter that has observed
  thousands of calls says the view paths spent nothing. A zero against a meter
  that has observed nothing says only that nobody has measured anything yet.

  Scoped to the meter's window rather than to all time, because that is what the
  snapshot holds — the page says "attributed" rather than "ever made" for the
  same reason.
  """
  @spec observed_calls(map()) :: non_neg_integer()
  def observed_calls(%{callers: callers}) when is_list(callers),
    do: Enum.reduce(callers, 0, &(calls(&1) + &2))

  def observed_calls(_snapshot), do: 0

  @doc """
  One time-series sample: whole-store counts and freshness, for the cache
  history charts.

  `project/1` is shaped for a page — truncation, per-type grouping, one re-read
  per render. A chart that summed its truncated `groups` would report freshness
  for a subset beside a total for the whole store, which is the silent-subset
  failure this page refuses elsewhere, so `history_sample/1` classifies **every**
  entry the source holds (the store caps itself at 100,000) and answers counts
  that sum to each other: `with_body + bodyless == total`, and for body-holding
  entries `fresh + stale + expired + unknown == with_body`.

  Classification reuses `CacheInspector.Entry.new/3` rather than restating the
  freshness rules, so the chart and the map tiles cannot drift apart about what
  "stale" and "expired" mean.

  Answers `nil` when the source is unavailable, so the sampler records nothing
  rather than recording a fabricated zero — the same distinction this page makes
  between "nothing cached" and "nothing observed".
  """
  @spec history_sample(DateTime.t(), keyword()) :: map() | nil
  def history_sample(now \\ DateTime.utc_now(), opts \\ []) do
    source = Keyword.get(opts, :source, configured_source())

    case read(source) do
      {:ok, raw} ->
        entries = Enum.map(raw, &Entry.new(&1, now, thresholds(opts)))
        freshness = Enum.frequencies_by(entries, & &1.freshness)

        %{
          t_ms: DateTime.to_unix(now, :millisecond),
          total: length(entries),
          with_body: Enum.count(entries, & &1.body?),
          bodyless: Enum.count(entries, & &1.bodyless?),
          fresh: Map.get(freshness, :fresh, 0),
          stale: Map.get(freshness, :stale, 0),
          expired: Map.get(freshness, :expired, 0),
          unknown: Map.get(freshness, :unknown, 0)
        }

      :unavailable ->
        nil
    end
  end

  @doc "Counts of every writer that has touched the cache, in canonical order."
  @spec writes_by_writer(map()) :: [{atom(), non_neg_integer()}]
  def writes_by_writer(%{entries: entries}) do
    counts = Enum.frequencies_by(entries, & &1.writer)

    Enum.map(@writers, &{&1, Map.get(counts, &1, 0)})
  end

  def writes_by_writer(_projection), do: Enum.map(@writers, &{&1, 0})

  defp calls(observation) do
    case Map.get(observation, :calls) do
      count when is_integer(count) and count > 0 -> count
      _none -> 0
    end
  end

  defp view_calls(observation) do
    case Map.get(observation, :view_calls) do
      count when is_integer(count) and count > 0 -> count
      _none -> 0
    end
  end

  defp read(source) do
    if source_available?(source), do: {:ok, source.entries()}, else: :unavailable
  rescue
    # A corrupt or half-built store must not take the page down with it. The
    # cache's own rule is that a failed cache costs throughput, never
    # correctness, and an inspector that crashes on a bad entry is strictly
    # less useful than one that says the store is unreadable.
    _unreadable -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  # `function_exported?/3` answers `false` for a module that is merely not
  # loaded yet, which under lazy loading makes a perfectly good source look
  # unavailable and renders the page's "no cache store is running" state over a
  # store that is running. Loading it first is the difference between asking
  # "can this source answer?" and asking "has anything happened to mention it?".
  defp source_available?(source) do
    Code.ensure_loaded?(source) and function_exported?(source, :available?, 0) and source.available?()
  end

  defp configured_source,
    do: Application.get_env(:aiur, :github_cache_inspector_source, ResourceStoreSource)

  defp thresholds(opts) do
    %{
      stale_after_ms: Keyword.get(opts, :stale_after_ms, @default_stale_after_ms),
      expired_after_ms: Keyword.get(opts, :expired_after_ms, @default_expired_after_ms)
    }
  end

  # Ordering decides what survives truncation, so the states that need
  # attention are put first: an entry holding a validator and no body, then the
  # stalest. An earlier version sorted on `-(age_ms || 0)`, which sent every
  # entry with no recorded fetch time to the *end* of its type — so a bodyless
  # entry, the exact state this page exists to surface, was the first thing
  # elided while the comment above it claimed the opposite.
  defp sort_key(entry) do
    {to_string(entry.resource_type), if(entry.bodyless?, do: 0, else: 1), -(entry.age_ms || 0), entry.identity}
  end

  defp groups(all, limit) do
    all
    |> Enum.group_by(& &1.resource_type)
    |> Enum.map(fn {resource_type, entries} ->
      counts = Enum.frequencies_by(entries, & &1.freshness)

      %{
        resource_type: resource_type,
        label: label(resource_type),
        count: length(entries),
        # Truncation is per type, not across the whole store. Taking one global
        # slice of a list sorted by type name would give an alphabetically-late
        # type zero rows while its tile still advertised a full count.
        shown: min(length(entries), limit),
        elided: max(length(entries) - limit, 0),
        bodyless: Enum.count(entries, & &1.bodyless?),
        freshness: Map.new(@freshness, &{&1, Map.get(counts, &1, 0)}),
        # The tile's colour. A region is as stale as its worst entry, because a
        # group averaged to "mostly fresh" hides the one entry a decision is
        # about to be made on.
        worst: worst(counts),
        stale_fraction: stale_fraction(counts, length(entries))
      }
    end)
    |> Enum.sort_by(&{-&1.count, to_string(&1.resource_type)})
  end

  # `:unknown` is not the worst state, it is an absent measurement, so it never
  # decides a tile's colour on its own. An expired entry beats a stale one and a
  # stale one beats fresh.
  defp worst(counts) do
    Enum.find([:expired, :stale, :unknown], :fresh, &(Map.get(counts, &1, 0) > 0))
  end

  defp stale_fraction(_counts, 0), do: 0.0

  defp stale_fraction(counts, total) do
    stale = Map.get(counts, :stale, 0) + Map.get(counts, :expired, 0)
    Float.round(stale / total, 4)
  end

  defp label(resource_type) do
    resource_type
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
