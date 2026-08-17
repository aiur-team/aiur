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
  """

  alias Aiur.GitHub.CacheInspector.{Entry, ResourceStoreSource}

  @default_limit 500
  # Freshness is expressed against how long an entry may be trusted, not against
  # a number chosen when polling was five seconds apart. `stale` is the point
  # past which a consumer should say it is reading history; `expired` is the
  # retention edge, where the store itself stops keeping the entry.
  @default_stale_after_ms 5 * 60 * 1000
  @default_expired_after_ms 72 * 60 * 60 * 1000

  @writers [:mutation, :webhook, :need, :sweep]
  @freshness [:fresh, :stale, :expired]

  @doc "The canonical writer buckets, in the order the page offers them."
  @spec writers() :: [atom()]
  def writers, do: @writers

  @doc "The freshness buckets, ordered from most to least trustworthy."
  @spec freshness_levels() :: [atom()]
  def freshness_levels, do: @freshness

  @doc """
  Everything the cache holds, grouped and classified.

  Takes no identity and no filter: filtering and sorting are the page's job and
  happen client-side over this one result, because a filter that re-read the
  store would make typing in a search box cost API budget by a longer route.
  """
  @spec project(keyword()) :: map()
  def project(opts \\ []) do
    source = Keyword.get(opts, :source, configured_source())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, @default_limit)

    case read(source) do
      {:ok, raw} ->
        entries =
          raw
          |> Enum.map(&Entry.new(&1, now, thresholds(opts)))
          |> Enum.sort_by(&sort_key/1)

        kept = Enum.take(entries, limit)

        %{
          available?: true,
          entries: kept,
          total: length(entries),
          elided: max(length(entries) - length(kept), 0),
          limit: limit,
          groups: groups(entries, kept),
          captured_at: now
        }

      :unavailable ->
        %{
          available?: false,
          entries: [],
          total: 0,
          elided: 0,
          limit: limit,
          groups: [],
          captured_at: now
        }
    end
  end

  @doc "One entry by its stable identity, or `nil`. Never fetches on a miss."
  @spec find(map(), String.t()) :: map() | nil
  def find(%{entries: entries}, identity) when is_binary(identity),
    do: Enum.find(entries, &(&1.identity == identity))

  def find(_projection, _identity), do: nil

  @doc """
  GitHub requests caused by somebody looking at a page.

  The headline figure on the debug page, and it must read zero. It counts the
  quota meter's observations whose call site declared itself a view path — a set
  that is empty by construction today, and whose becoming non-empty is exactly
  the regression worth seeing immediately. Reading a derived zero rather than
  hard-coding one is the difference between a claim and a measurement.
  """
  @spec view_fetches(map()) :: non_neg_integer()
  def view_fetches(%{callers: callers}) when is_list(callers) do
    callers
    |> Enum.filter(&String.starts_with?(to_string(&1.caller), "view:"))
    |> Enum.reduce(0, &(&1.calls + &2))
  end

  def view_fetches(_snapshot), do: 0

  @doc "Counts of every writer that has touched the cache, in canonical order."
  @spec writes_by_writer(map()) :: [{atom(), non_neg_integer()}]
  def writes_by_writer(%{entries: entries}) do
    counts = Enum.frequencies_by(entries, & &1.writer)

    Enum.map(@writers ++ [:other], &{&1, Map.get(counts, &1, 0)})
  end

  def writes_by_writer(_projection), do: Enum.map(@writers ++ [:other], &{&1, 0})

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

  defp source_available?(source), do: function_exported?(source, :available?, 0) and source.available?()

  defp configured_source,
    do: Application.get_env(:aiur, :github_cache_inspector_source, ResourceStoreSource)

  defp thresholds(opts) do
    %{
      stale_after_ms: Keyword.get(opts, :stale_after_ms, @default_stale_after_ms),
      expired_after_ms: Keyword.get(opts, :expired_after_ms, @default_expired_after_ms)
    }
  end

  # Stalest first inside a type, so the region that needs attention is the one
  # that survives truncation. Truncating the *interesting* end would make the
  # elision notice actively misleading.
  defp sort_key(entry), do: {to_string(entry.resource_type), -(entry.age_ms || 0), entry.identity}

  defp groups(all, kept) do
    shown = Enum.frequencies_by(kept, & &1.resource_type)

    all
    |> Enum.group_by(& &1.resource_type)
    |> Enum.map(fn {resource_type, entries} ->
      counts = Enum.frequencies_by(entries, & &1.freshness)

      %{
        resource_type: resource_type,
        label: label(resource_type),
        count: length(entries),
        shown: Map.get(shown, resource_type, 0),
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

  defp worst(counts) do
    Enum.find(Enum.reverse(@freshness), :fresh, &(Map.get(counts, &1, 0) > 0))
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
