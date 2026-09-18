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

  A blocker's record is judged by when its whole body was last written or
  confirmed (`full_body_at_ms`), so a label write does not make an old `"state"`
  look fresh. A same-repository blocker the record holds as open, but that the
  latest complete open-issue listing (`Aiur.GitHub.OpenIssueSnapshot`, taken
  after the record) no longer names, has closed on GitHub, and its record counts
  as stale. That is how a close by any route (a PR closing several tickets, a
  manual close, a lost webhook) releases its dependents on the next pass.

  When any blocker's `:issue` record is missing, stale or closed by that signal,
  the whole list is re-read unconditionally, as before #2714. That read proves
  every blocker's state as of now, so each embedded blocker is merged into its
  `:issue` record (never over a newer one). The next dependent that shares the
  blocker, and the next dispatch pass, then need no read.

  ## Cost and bounds

  With `B = max_age_ms/0` (15 minutes by default), a dependent that stays held
  costs at most one `blocked_by` read per `B`, whatever the dispatch cadence,
  instead of one per pass. A blocker that closes, as the store sees it, releases
  its dependent on the next pass with no read at all. A same-repository blocker
  closed without the store seeing it releases its dependent on the first pass
  after the next complete open-issue poll, for one read.

  Fail-closed is kept: an unreadable list is an error, and a blocker with no
  derivable state holds dispatch. The price of the cache is bounded staleness in
  two directions, both stated:

    * a blocker added on GitHub's side with no Aiur write and no webhook delivery
      holds its dependent within `B` of being added;
    * an edge removed on GitHub's side with no webhook delivery stops holding its
      dependent within `B`;
    * a blocker in another repository that closes with no store update stops
      holding its dependent within `B`, because the open-issue listing covers
      only the tracker repository.
  """

  alias Aiur.GitHub.{DependenciesApi, OpenIssueSnapshot, ResourceStore, Transport}

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

      open_issues = OpenIssueSnapshot.fetch(owner, repo, max_age_ms)

      with {:ok, edges} <- fresh_edges(ResourceStore.key(:issue_blocked_by, owner, repo, issue_number), max_age_ms),
           {:ok, blockers} <- current_blockers(edges, {owner, repo}, open_issues, max_age_ms) do
        {:ok, blockers}
      else
        :stale -> read_blockers(issue_number, owner, repo, opts)
      end
    end
  end

  defp current_blockers(edges, {owner, repo} = tracker_repo, open_issues, max_age_ms) when is_list(edges) do
    Enum.reduce_while(edges, {:ok, []}, fn edge, {:ok, acc} ->
      with {:ok, blocker, full_body_at_ms} <- fresh_blocker(blocker_key(edge, owner, repo), max_age_ms),
           false <- closed_since_recorded?(blocker, full_body_at_ms, tracker_repo, open_issues) do
        {:cont, {:ok, [blocker | acc]}}
      else
        _stale_missing_or_closed -> {:halt, :stale}
      end
    end)
    |> case do
      {:ok, blockers} -> {:ok, Enum.reverse(blockers)}
      :stale -> :stale
    end
  end

  defp current_blockers(_edges, _tracker_repo, _open_issues, _max_age_ms), do: :stale

  defp fresh_edges(nil, _max_age_ms), do: :stale

  defp fresh_edges(key, max_age_ms) do
    case ResourceStore.fetch(key) do
      {:ok, %{data: edges, fetched_at_ms: fetched_at_ms}} when is_list(edges) ->
        if within?(fetched_at_ms, max_age_ms), do: {:ok, edges}, else: :stale

      _miss ->
        :stale
    end
  end

  # A blocker's state is judged by when its whole body was last written or
  # confirmed, not by `:fetched_at_ms`: a label write moves that clock while
  # leaving `"state"` as old as it was.
  defp fresh_blocker(nil, _max_age_ms), do: :stale

  defp fresh_blocker(key, max_age_ms) do
    case ResourceStore.fetch(key) do
      {:ok, %{data: blocker, full_body_at_ms: full_body_at_ms}} when is_map(blocker) ->
        if within?(full_body_at_ms, max_age_ms), do: {:ok, blocker, full_body_at_ms}, else: :stale

      _miss ->
        :stale
    end
  end

  defp within?(at_ms, max_age_ms) when is_integer(at_ms), do: System.system_time(:millisecond) - at_ms <= max_age_ms
  defp within?(_at_ms, _max_age_ms), do: false

  # The close signal. A blocker in the tracker repository that the store holds
  # as open, but that a complete open-issue listing taken *after* that record
  # no longer names, has closed on GitHub by some route the store did not see.
  # The record is then stale, and one re-read writes the closed state back. A
  # listing older than the record says nothing (the blocker may have opened or
  # reopened since), and a blocker in another repository is not in the listing
  # at all, so both keep the time bound alone.
  defp closed_since_recorded?(%{"state" => "open"} = blocker, full_body_at_ms, {owner, repo}, {:ok, open, taken_at_ms}) do
    same_repository?(blocker_repository(blocker, owner, repo), {owner, repo}) and taken_at_ms > full_body_at_ms and
      not MapSet.member?(open, to_string(Map.get(blocker, "number")))
  end

  defp closed_since_recorded?(_blocker, _full_body_at_ms, _tracker_repo, _open_issues), do: false

  defp same_repository?({owner_a, repo_a}, {owner_b, repo_b}),
    do: String.downcase(owner_a) == String.downcase(owner_b) and String.downcase(repo_a) == String.downcase(repo_b)

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
