defmodule Aiur.GitHub.OpenIssueSnapshot do
  @moduledoc """
  The open issue numbers, labels and update times from the latest complete listing.

  The candidate poll lists `issues?state=open` unfiltered on every tick, so each
  successful, fully paginated listing names every open issue in the tracker
  repository. An issue that the store still holds as open but that this set no
  longer names has closed on GitHub. `Aiur.GitHub.BoundedBlockedBy` uses that as
  its close signal, so a blocker closed by any route (a PR closing several
  tickets, a manual close, a lost webhook) releases its dependents on the next
  pass instead of when its `:issue` record ages out (#2714).

  Only a complete listing is recorded. A failed or partial read records nothing,
  and the previous snapshot stays until it ages out. A missing snapshot only
  removes the close signal; it never releases a dependent.

  The table is owned by this module's own supervised process, started with
  the application before anything that polls. It must not belong to a writer:
  short-lived processes also list open issues, and a table owned by one of
  them would vanish with it. With no table (the process is not running), a
  write is dropped and a read answers `:none`.
  """

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Records open issue numbers and label observations from a complete listing for `owner/repo`."
  @spec put(String.t(), String.t(), [String.t() | integer()], Aiur.Tracker.open_issue_label_map()) :: :ok
  def put(owner, repo, numbers, labels_by_id \\ %{}) when is_binary(owner) and is_binary(repo) and is_list(numbers) and is_map(labels_by_id) do
    set = MapSet.new(numbers, &to_string/1)
    key = repo_key(owner, repo)
    taken_at_ms = now_ms()
    :ets.insert(@table, [{key, set, taken_at_ms}, {{:labels, key}, labels_by_id, taken_at_ms}])
    broadcast(taken_at_ms)
    :ok
  rescue
    # No table: the owner is not running. Dropping the snapshot only removes
    # the close signal; it never releases a dependent.
    ArgumentError -> :ok
  end

  @doc """
  The latest snapshot for `owner/repo` and when it was taken, or `:none` when
  there is no snapshot or it is older than `max_age_ms`.
  """
  @spec fetch(String.t(), String.t(), pos_integer()) :: {:ok, MapSet.t(String.t()), integer()} | :none
  def fetch(owner, repo, max_age_ms) when is_binary(owner) and is_binary(repo) do
    fetch_snapshot(repo_key(owner, repo), max_age_ms)
  end

  @doc "Returns labels and update times from the latest complete listing, or `:none` if absent or stale."
  @spec fetch_labels(String.t(), String.t(), pos_integer()) :: {:ok, Aiur.Tracker.open_issue_label_map(), integer()} | :none
  def fetch_labels(owner, repo, max_age_ms) when is_binary(owner) and is_binary(repo) do
    fetch_snapshot({:labels, repo_key(owner, repo)}, max_age_ms)
  end

  defp fetch_snapshot(key, max_age_ms) do
    case lookup(key) do
      {snapshot, taken_at_ms} -> if now_ms() - taken_at_ms <= max_age_ms, do: {:ok, snapshot, taken_at_ms}, else: :none
      nil -> :none
    end
  end

  defp broadcast(taken_at_ms) do
    if Process.whereis(Aiur.PubSub) do
      Phoenix.PubSub.broadcast(Aiur.PubSub, "tracker:open_issues", {:open_issues_recorded, taken_at_ms})
    end
  end

  @doc "Removes every snapshot. For tests."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, set, taken_at_ms}] -> {set, taken_at_ms}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp repo_key(owner, repo), do: String.downcase("#{owner}/#{repo}")

  defp now_ms, do: System.system_time(:millisecond)
end
