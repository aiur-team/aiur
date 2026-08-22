defmodule Aiur.GitHub.DeliveredPullRequest do
  @moduledoc """
  The poll pipe's read side of `Aiur.GitHub.ResourceStore`: *which* open pull
  request belongs to a ticket, when a webhook delivery already said so.

  `Aiur.Events.GithubWebhook.Deposit` writes every delivered pull request under
  `{:branch_pull_request, owner, repo, ticket}` — keyed by the ticket its head
  branch belongs to, which is the identity a poller holds *before* it has done
  any lookup. That deposit costs nothing: GitHub paid for the round trip and the
  delivery arrived first. Until this module existed nothing on the poll side
  read it, so `Aiur.GitHub.CommentPollBatch` and `Aiur.GitHub.CIPollBatch` kept
  paying for up to two speculative `pullRequests(headRefName: …)` connections
  per target to rediscover a number the store was already holding.

  ## What this answers, and what it deliberately does not

  **Only the number.** This is an identity lookup and nothing else. The batches
  still ask GitHub, this cycle, for every field whose staleness could make the
  daemon act wrongly — `reviewDecision`, `reviewThreads`, `mergeable`,
  `statusCheckRollup`. Those are exactly the selections
  `Aiur.GitHub.ReadCache.Policy` refuses on purpose, and knowing which pull
  request to ask about is not the same as answering what its verdict is. A
  delivery is fresher than a poll, so deferring to it for identity is sound;
  serving a verdict from it would not be, and this module gives no caller the
  means to.

  ## Freshness is keyed on `fetched_at_ms`, never `recorded_at_ms`

  `recorded_at_ms` is touched by *every* write, including a bodyless
  processed-mark, so an entry whose body is hours old reads as freshly recorded
  the moment some pipe marks it handled. `fetched_at_ms` describes the body
  itself, which is what "do I already have this" has to mean — the same field
  `ResourceStore.fetch/1` expires on. `ResourceStore.fetch/1` already declines a
  body past the retention window; the shorter bound here is this module's own,
  because an identity a poller acts on should not be a day old when a cheap
  query would confirm it.

  ## Two guards against acting on a pull request that has moved on

    * **The body must have come from a delivery** (`:data_source == :webhook`,
      surfaced by `ResourceStore.fetch/1` as `:source`). That is the
      "distinguish delivered from polled" the store already carries. A body some
      other reader's fetch deposited is not wrong, but it is not free either,
      and restricting to deliveries keeps the saving attributable.
    * **The delivered pull request must still be open.** GitHub permits one open
      pull request per head/base pair, so a ticket's second pull request only
      exists once the first closed — and the `pull_request` delivery for that
      close overwrites this very entry with `"state" => "closed"`. The guard is
      therefore self-healing: the entry that would send a poller to a stale
      number is the entry this check refuses.
    * **The delivered head repository must be the tracked repository.** A fork
      can reuse the same ticket branch name, so the cached number is not an
      identity unless `head.repo.full_name` also matches the repository whose
      store key was read.

  Every fault — store not running, no entry, unreadable body — answers `nil`,
  which puts the caller back on the branch-discovery path it used before. A
  store that cannot answer costs throughput, never correctness.
  """

  alias Aiur.GitHub.ResourceStore

  # Long enough that a ticket under active work is nearly always covered (a
  # push, a review or a comment all deliver a `pull_request` body), short enough
  # that an identity nothing has confirmed for most of a working day is bought
  # again rather than assumed.
  @max_age_ms 6 * 60 * 60 * 1000

  @doc """
  The number of the open pull request a delivery recorded for `target`, or
  `nil`.

  `opts` may carry `:delivered_identity_max_age_ms` to override the freshness
  bound (`0` refuses every held identity), and `:delivered_identity` set to
  `false` to opt out entirely — the latter exists so a caller can be measured
  against its own pre-store behaviour without unwiring the module.
  """
  @spec number_for_target(String.t(), String.t(), String.t(), keyword()) :: pos_integer() | nil
  def number_for_target(target, owner, repo, opts \\ [])

  def number_for_target(target, owner, repo, opts)
      when is_binary(target) and is_binary(owner) and is_binary(repo) do
    if Keyword.get(opts, :delivered_identity, true) do
      :branch_pull_request
      |> ResourceStore.key(owner, repo, target)
      |> held_number("#{owner}/#{repo}", opts)
    end
  end

  def number_for_target(_target, _owner, _repo, _opts), do: nil

  @doc "The freshness bound this module applies, in milliseconds."
  @spec max_age_ms(keyword()) :: pos_integer()
  def max_age_ms(opts \\ []) do
    case Keyword.get(opts, :delivered_identity_max_age_ms) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @max_age_ms
    end
  end

  defp held_number(nil, _expected_repo, _opts), do: nil

  defp held_number(key, expected_repo, opts) do
    case ResourceStore.fetch(key) do
      {:ok, entry} -> if delivered?(entry) and fresh?(entry, opts), do: open_number(Map.get(entry, :data), expected_repo)
      :miss -> nil
    end
  end

  defp delivered?(%{source: :webhook}), do: true
  defp delivered?(_entry), do: false

  # `fetched_at_ms` describes the body. `recorded_at_ms` describes the last
  # write of any kind and would let a processed-mark make an old body look new.
  defp fresh?(%{fetched_at_ms: fetched_at_ms}, opts) when is_integer(fetched_at_ms) do
    System.system_time(:millisecond) - fetched_at_ms < max_age_ms(opts)
  end

  defp fresh?(_entry, _opts), do: false

  defp open_number(%{"number" => number, "state" => state} = body, expected_repo) when is_integer(number) and number > 0 do
    if String.downcase(to_string(state)) == "open" and same_repo?(get_in(body, ["head", "repo", "full_name"]), expected_repo), do: number
  end

  defp open_number(_body, _expected_repo), do: nil

  defp same_repo?(actual, expected) when is_binary(actual) and actual != "" and is_binary(expected),
    do: String.downcase(actual) == String.downcase(expected)

  defp same_repo?(_actual, _expected), do: false
end
