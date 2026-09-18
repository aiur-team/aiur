defmodule Aiur.GitHub.BoundedBlockedBy do
  @moduledoc """
  The dispatch gate's `blocked_by` read, split into edges and blocker states.

  `/issues/:n/dependencies/blocked_by` answers two questions at once: *which*
  issues block `n` (the edges), and *what state* each of them is in (the
  embedded blocker objects). The two change at very different rates, and only
  one of them can be revalidated.

    * **Edges** change rarely, and Aiur learns most changes for free: its own
      dependency writes and the `issue_dependencies` webhook both update the held
      `:issue_blocked_by` entry. The endpoint's ETag tracks the blocked issue, so a
      conditional read cannot confirm them (#2550, #2552). A held edge list is
      therefore served while it is younger than `max_age_ms/0`, and re-read
      unconditionally once it is older.
    * **Blocker states** are taken from each blocker's own `:issue` record, which
      the running-issue poll, the ticket-detail read, Aiur's mutations and the
      `issues` webhook keep current. On Khala, #53's `:issue` entry said closed
      while the held `blocked_by` body still said open (#2714). The states the
      held body embeds are never used: they are exactly the stale snapshot #2550
      stalled a fleet on.

  When any blocker's `:issue` record is missing or older than `max_age_ms/0`,
  the whole list is re-read unconditionally, as before #2714. That read proves
  every blocker's state as of now, so each embedded blocker is merged into its
  `:issue` record (never over a newer one). The next dependent that shares the
  blocker, and the next dispatch pass, then need no read.

  ## Cost and bounds

  With `B = max_age_ms/0` (15 minutes by default), a dependent that stays held
  costs at most one `blocked_by` read per `B`, whatever the dispatch cadence,
  instead of one per pass. A blocker that closes, as the store sees it, releases
  its dependent on the next pass with no read at all.

  Fail-closed is kept: an unreadable list is an error, and a blocker with no
  derivable state holds dispatch. The price of the cache is bounded staleness in
  two directions, both stated:

    * a blocker added on GitHub's side with no Aiur write and no webhook delivery
      holds its dependent within `B` of being added;
    * an edge removed on GitHub's side with no webhook delivery stops holding its
      dependent within `B`.
  """

  alias Aiur.GitHub.{DependenciesApi, ResourceStore, Transport}

  @default_max_age_ms :timer.minutes(15)

  @doc """
  The staleness bound, in milliseconds, for both the held edge list and each
  blocker's `:issue` record. Configurable with `:aiur, :blocked_by_max_age_ms`.
  """
  @spec max_age_ms() :: pos_integer()
  def max_age_ms do
    case Application.get_env(:aiur, :blocked_by_max_age_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _unset -> @default_max_age_ms
    end
  end

  @doc """
  Answers the raw blocker objects for `issue_number`, each carrying a state no
  older than `max_age_ms/0`. The shape is the endpoint's, so the caller
  normalizes it exactly as it normalizes a fresh read.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch(issue_number, opts \\ []) do
    with {:ok, {owner, repo}} <- Transport.parse_repo() do
      max_age_ms = max_age_ms()

      with {:ok, edges} <- fresh_body(ResourceStore.key(:issue_blocked_by, owner, repo, issue_number), max_age_ms),
           {:ok, blockers} <- current_blockers(edges, owner, repo, max_age_ms) do
        {:ok, blockers}
      else
        :stale -> read_blockers(issue_number, owner, repo, opts)
      end
    end
  end

  defp current_blockers(edges, owner, repo, max_age_ms) when is_list(edges) do
    Enum.reduce_while(edges, {:ok, []}, fn edge, {:ok, acc} ->
      case fresh_body(blocker_key(edge, owner, repo), max_age_ms) do
        {:ok, blocker} when is_map(blocker) -> {:cont, {:ok, [blocker | acc]}}
        _stale_or_missing -> {:halt, :stale}
      end
    end)
    |> case do
      {:ok, blockers} -> {:ok, Enum.reverse(blockers)}
      :stale -> :stale
    end
  end

  defp current_blockers(_edges, _owner, _repo, _max_age_ms), do: :stale

  defp fresh_body(nil, _max_age_ms), do: :stale

  defp fresh_body(key, max_age_ms) do
    case ResourceStore.fetch(key) do
      {:ok, %{data: data, fetched_at_ms: fetched_at_ms}} when is_integer(fetched_at_ms) and not is_nil(data) ->
        if System.system_time(:millisecond) - fetched_at_ms <= max_age_ms, do: {:ok, data}, else: :stale

      _miss ->
        :stale
    end
  end

  # The unconditional read is the truth as of now, for the edges and for every
  # blocker it embeds. `DependenciesApi` stores the edges; the states go to each
  # blocker's `:issue` record so later passes read them from there.
  defp read_blockers(issue_number, owner, repo, opts) do
    with {:ok, blockers} <- DependenciesApi.fetch_blocked_by(issue_number, Keyword.put(opts, :revalidate, true)) do
      Enum.each(blockers, &deposit_blocker(&1, owner, repo))
      {:ok, blockers}
    end
  end

  # Merged into the held body rather than written over it: the dependencies
  # endpoint's blocker object must not strip a field the ticket-detail read put
  # there. The merge is refused, inside the store's compare-and-swap, when the
  # held body is strictly newer, so a webhook delivery that raced this read is
  # never rolled back. An unchanged merge still moves `fetched_at_ms`, which is
  # the point: the state was just proved current.
  defp deposit_blocker(blocker, owner, repo) when is_map(blocker) do
    case blocker_key(blocker, owner, repo) do
      nil ->
        :ok

      key ->
        ResourceStore.update_resource(key, &merge_blocker(&1, blocker), source: :fetch, version: &updated_at/1)
        :ok
    end
  end

  defp deposit_blocker(_blocker, _owner, _repo), do: :ok

  defp merge_blocker(held, blocker) when is_map(held) do
    held_version = updated_at(held)
    version = updated_at(blocker)

    if is_binary(held_version) and is_binary(version) and version < held_version,
      do: :unchanged,
      else: Map.merge(held, blocker)
  end

  defp merge_blocker(_absent, blocker), do: blocker

  defp updated_at(%{"updated_at" => version}) when is_binary(version) and version != "", do: version
  defp updated_at(_body), do: nil

  # A blocker can live in another repository, and an issue number is only unique
  # within one, so the `:issue` key is the blocker's own repository. GitHub always
  # sends `repository_url`; the tracker repository is the fallback only for a
  # body that names none.
  defp blocker_key(%{"number" => number} = blocker, owner, repo) when is_integer(number) or is_binary(number) do
    {blocker_owner, blocker_repo} = blocker_repository(blocker, owner, repo)
    ResourceStore.key(:issue, blocker_owner, blocker_repo, to_string(number))
  end

  defp blocker_key(_blocker, _owner, _repo), do: nil

  defp blocker_repository(%{"repository_url" => url}, owner, repo) when is_binary(url) do
    case url |> URI.parse() |> Map.get(:path) |> to_string() |> String.split("/", trim: true) |> Enum.take(-3) do
      ["repos", blocker_owner, blocker_repo] -> {blocker_owner, blocker_repo}
      _unparseable -> {owner, repo}
    end
  end

  defp blocker_repository(_blocker, owner, repo), do: {owner, repo}
end
