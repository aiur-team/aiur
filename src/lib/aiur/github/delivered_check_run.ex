defmodule Aiur.GitHub.DeliveredCheckRun do
  @moduledoc """
  The CI poll pipe's read side of `Aiur.GitHub.ResourceStore`: whether a
  `check_run` delivery has already answered a target, so `Aiur.GitHub.CIPollBatch`
  can drop that target from its GraphQL document instead of paying for a read
  GitHub just sent for free (#2310).

  `Aiur.Events.GithubWebhook.Deposit` writes every delivered check run under
  `{:check_run, owner, repo, ticket}` — keyed by the ticket its head branch
  belongs to, which is the identity the poll pipe holds before it has done any
  lookup. This module is that poll-side reader.

  ## What this answers, and what it deliberately does not

  **Only whether a delivery displaced the target's read.** The batch still asks
  GitHub, on every non-displaced cycle, for the full rollup and every merge
  verdict; this module never answers a verdict from the held body. The served
  (displaced) result is classified conservatively by `GithubCIPoller` and can
  never yield `:passed` — the R10 boundary (`read_cache/policy.ex` refuses
  `statusCheckRollup`/`CheckRun` on purpose) is preserved because a CI verdict
  is still never *answered* from a cache, only the redundant *read* is skipped
  on the strength of a fresh delivery.

  ## "Has this been deposited since I last read it?"

  The deposit never marks processed; the poll that serves it marks it processed
  at the run's marker (`completed_at || started_at || id`). So "unprocessed"
  is exactly "a delivery landed since the last poll read", and a served delivery
  displaces precisely one poll cycle — the next one fetches and re-establishes
  the full rollup, which is the safety net a dropped delivery relies on.

  ## Fail toward polling (the #2276 lesson)

  Every gate here fails open to a fetch:

    * **delivered** — only a `:webhook`-written body counts; a poll-written
      entry is not free and must be fetched;
    * **fresh** — an entry past its freshness bound is bought again;
    * **unprocessed** — a delivery already consumed by a poll is old news;
    * **head match** — the delivered run must be on the head the last poll
      observed; a moved head fetches;
    * **id match** — the delivered run must be a run the last poll actually saw;
      an unmatched or unknown check-run id (a run registered since the last
      read, which is exactly the #2276 false-`:passed` hazard) fetches.

  Every fault — store not running, no entry, unreadable body — answers `:miss`,
  which puts the caller on the fetch path it used before. A store that cannot
  answer costs throughput, never correctness.
  """

  alias Aiur.GitHub.ResourceStore

  # The displacement is a skip of one read immediately following a delivery;
  # a deposit the poll never consumed within this window is old news and must
  # not skip a fresh read. Bounded well below the store's 72 h retention, like
  # `DeliveredPullRequest`'s bound but tighter, because a CI skip is freshness,
  # not identity.
  @max_age_ms 30 * 60 * 1000

  @doc """
  The delivered check run that answers `target`, or `:miss`.

  `owner`/`repo` name the repository; `opts` may carry:

    * `:delivered_check_run_max_age_ms` — override the freshness bound
      (`0` refuses every held entry);
    * `:ci_heads_by_target` — map of target to the head sha its last poll
      observed; a deposit whose run is on a different head does not answer;
    * `:ci_check_run_ids_by_target` — map of target to the check-run ids its
      last poll observed; a run with an id outside that set does not answer.

  Returns `{:ok, %{key: key, check_run: check_run, marker: marker, head_sha: head_sha}}`
  on a qualifying hit, `:miss` otherwise.
  """
  @spec signal_for_target(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | :miss
  def signal_for_target(target, owner, repo, opts \\ [])

  def signal_for_target(target, owner, repo, opts)
      when is_binary(target) and is_binary(owner) and is_binary(repo) do
    key = ResourceStore.key(:check_run, owner, repo, target)

    with {:ok, entry} <- held_entry(key),
         check_run when is_map(check_run) <- check_run(entry),
         true <- delivered?(entry),
         true <- fresh?(entry, opts),
         true <- unprocessed?(key, entry),
         true <- head_matches?(check_run, target, opts),
         true <- id_matches?(check_run, target, opts) do
      {:ok,
       %{
         key: key,
         check_run: check_run,
         marker: Map.get(entry, :version),
         head_sha: Map.get(check_run, "head_sha")
       }}
    else
      _other -> :miss
    end
  end

  def signal_for_target(_target, _owner, _repo, _opts), do: :miss

  @doc """
  Marks a served deposit processed at its marker, so the next poll cycle
  fetches the full rollup rather than re-serving the same delivery.
  """
  @spec mark_served(map()) :: :ok
  def mark_served(%{key: key, marker: marker}) do
    ResourceStore.mark_processed(key, :poll, marker)
  end

  @doc "The freshness bound this module applies, in milliseconds."
  @spec max_age_ms(keyword()) :: pos_integer()
  def max_age_ms(opts \\ []) do
    case Keyword.get(opts, :delivered_check_run_max_age_ms) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @max_age_ms
    end
  end

  defp held_entry(nil), do: :miss

  defp held_entry(key) do
    case ResourceStore.fetch(key) do
      {:ok, entry} -> {:ok, entry}
      :miss -> :miss
    end
  end

  # The poll's `mark_processed/3` records `:source`; the deposit records
  # `:data_source`, and `fetch/1` surfaces the body's writer first. A body that
  # no delivery ever wrote is not free and must not displace.
  defp delivered?(%{source: :webhook}), do: true
  defp delivered?(_entry), do: false

  # `fetched_at_ms` describes the body, not the last write of any kind — the
  # same field `ResourceStore.fetch/1` expires on, and the same choice
  # `DeliveredPullRequest` makes.
  defp fresh?(%{fetched_at_ms: fetched_at_ms}, opts) when is_integer(fetched_at_ms) do
    System.system_time(:millisecond) - fetched_at_ms < max_age_ms(opts)
  end

  defp fresh?(_entry, _opts), do: false

  # "Deposited since the last poll read". The deposit never marks processed; a
  # poll that serves it does. A delivery already consumed by a poll displaces
  # nothing, and a delivery with a newer marker is unprocessed again.
  defp unprocessed?(key, %{version: marker}) do
    not ResourceStore.processed?(key, marker)
  end

  defp unprocessed?(_key, _entry), do: false

  # The delivered run must sit on the head the last poll observed, and be a run
  # that poll actually saw. Anything else means the delivery is not an answer
  # to the question the poll is about to ask — a new head, or a new run created
  # since the baseline — so the poll fetches (the #2276 failure, kept on the
  # polling side of the line).
  defp head_matches?(check_run, target, opts) do
    case Map.get(check_run, "head_sha") do
      delivered_head when is_binary(delivered_head) and delivered_head != "" ->
        case Keyword.get(opts, :ci_heads_by_target, %{}) |> Map.get(target) do
          ^delivered_head -> true
          _other -> false
        end

      _other ->
        false
    end
  end

  defp id_matches?(check_run, target, opts) do
    case Map.get(check_run, "id") do
      id when is_integer(id) or is_binary(id) ->
        Keyword.get(opts, :ci_check_run_ids_by_target, %{})
        |> Map.get(target, [])
        |> Enum.member?(id)

      _other ->
        false
    end
  end

  defp check_run(%{data: check_run}) when is_map(check_run), do: check_run
  defp check_run(_entry), do: :miss
end
