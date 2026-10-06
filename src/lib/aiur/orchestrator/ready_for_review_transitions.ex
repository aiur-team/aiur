defmodule Aiur.Orchestrator.ReadyForReviewTransitions do
  @moduledoc """
  Publishes `ticket.<id>.pr.ready_for_review` from what the polls see (#2707).

  GitHub's repository Events API does not carry draft-to-ready transitions, so
  on a repository with no webhook `gh pr ready` is invisible unless a poll
  notices the PR's draft flag. Two polls already read that flag at no extra
  request cost:

    * the CI poll (`CiLifecycle`), for tickets in `ci-wait` and `human-review`;
    * the comment poll (`GithubCommentsPoller`), for running tickets and the
      review and watch sets.

  Comparing two consecutive observations is not enough. An agent usually marks
  its PR ready while its ticket is `in-progress`, which the CI poll never reads;
  a ticket that leaves `ci-wait` loses its CI poll cache entry; and a daemon
  restart loses everything in memory. So the decision rests on state, kept per
  `{ticket, pr_number}` in `Aiur.PrReadyLedgerStore` and shared by both polls:

    * a draft observation records `:draft`;
    * a ready observation of a `:draft` PR publishes and records
      `{:announced, head_sha}`;
    * a ready observation of a PR the ledger does not know is resolved from the
      PR's history (`GitHub.Client.fetch_pull_request_was_draft/2`), which the
      comment poll reads once per such PR: a PR that was a draft publishes, and
      a PR opened ready records `:never_draft` and publishes nothing, as the
      webhook does. The CI poll does not read history, so it leaves an unknown
      PR for the comment poll.

  Each draft period of a PR therefore gets exactly one wake, at the head the
  poll saw. The publish carries the webhook's dedup key
  (`GithubKeys.pr_dedup_key(repo, pr, "ready_for_review", head_sha)`), so a
  webhook delivery and a poll of the same transition produce one event.
  """

  alias Aiur.Events.{GithubKeys, Publisher}
  alias Aiur.GitHub.Config, as: GitHubConfig
  alias Aiur.Orchestrator.State
  alias Aiur.PrReadyLedgerStore

  # Entries for merged and closed PRs are never observed again. Keep the
  # newest PRs only, so the ledger stays small without tracking PR closure.
  @max_entries 1_000

  # A failed history read (a 403 or 404 that persists, a transient error) is
  # retried after this long, not on every comment poll.
  @history_retry_ms 15 * 60 * 1_000

  @type observation :: %{
          required(:ticket) => String.t(),
          required(:pr_number) => pos_integer(),
          required(:head_sha) => String.t(),
          required(:draft?) => boolean(),
          optional(:was_draft?) => boolean() | :error | nil
        }

  @doc """
  Builds an observation from its parts, or `nil` when any part is missing: an
  unknown draft flag is not evidence of anything.
  """
  @spec observation(term(), term(), term(), term()) :: observation() | nil
  def observation(ticket, pr_number, head_sha, draft?)
      when is_binary(ticket) and ticket != "" and is_integer(pr_number) and pr_number > 0 and
             is_binary(head_sha) and head_sha != "" and is_boolean(draft?) do
    %{ticket: ticket, pr_number: pr_number, head_sha: head_sha, draft?: draft?}
  end

  def observation(_ticket, _pr_number, _head_sha, _draft?), do: nil

  @doc """
  Builds an observation from a PR body in REST (`"draft"`) or normalized batch
  shape. The ticket comes from the PR's head branch, as it does for the webhook,
  so a watched PR on a non-ticket branch yields `nil`.
  """
  @spec from_pull_request(term()) :: observation() | nil
  def from_pull_request(%{} = pr) do
    head = Map.get(pr, "head")

    with %{} <- head,
         ref when is_binary(ref) <- Map.get(head, "ref"),
         {:ticket, ticket, _topic} <- GithubKeys.ref_to_topic("refs/heads/" <> ref) do
      observation(ticket, Map.get(pr, "number"), Map.get(head, "sha"), Map.get(pr, "draft"))
    else
      _ -> nil
    end
  end

  def from_pull_request(_pr), do: nil

  @doc """
  True when `observation` is a ready PR the ledger has never seen, which only
  the PR's history can classify.
  """
  @spec needs_history?(PrReadyLedgerStore.ledger(), observation() | nil, integer()) :: boolean()
  def needs_history?(ledger, observation, now_ms \\ System.system_time(:millisecond))

  def needs_history?(ledger, %{draft?: false, ticket: ticket, pr_number: pr_number}, now_ms) when is_map(ledger) do
    case Map.get(ledger, {ticket, pr_number}) do
      nil -> true
      {:history_failed, retry_at_ms} -> now_ms >= retry_at_ms
      _known -> false
    end
  end

  def needs_history?(_ledger, _observation, _now_ms), do: false

  @doc """
  Returns the ledger, loading it from disk on first use.
  """
  @spec ledger(State.t()) :: PrReadyLedgerStore.ledger()
  def ledger(%State{pr_ready_ledger: ledger}) when is_map(ledger), do: ledger
  def ledger(%State{}), do: PrReadyLedgerStore.load()

  @doc """
  Folds observations into the ledger, publishes what they reveal, and persists
  the ledger when it changed.
  """
  @spec observe(State.t(), [observation() | nil], keyword()) :: State.t()
  def observe(%State{} = state, observations, opts \\ []) when is_list(observations) do
    ledger = ledger(state)
    next = Enum.reduce(observations, ledger, &apply_observation(&2, &1, opts))

    if next != ledger do
      next = prune(next)
      :ok = PrReadyLedgerStore.save(next)
      %{state | pr_ready_ledger: next}
    else
      %{state | pr_ready_ledger: ledger}
    end
  end

  defp apply_observation(ledger, %{ticket: ticket, pr_number: pr_number, draft?: draft?} = observation, opts) do
    key = {ticket, pr_number}

    case {draft?, Map.get(ledger, key)} do
      # The comment poll folds an observation taken when its task started, so
      # a stale draft reading can arrive after the CI poll already announced
      # the same head. The fold is monotonic for that head: only a draft at a
      # different head re-arms the PR. A real same-head re-draft loses nothing,
      # because its next ready would carry the announced dedup key anyway.
      {true, {:announced, head_sha}} ->
        if head_sha == observation.head_sha, do: ledger, else: Map.put(ledger, key, :draft)

      {true, _entry} ->
        Map.put(ledger, key, :draft)

      {false, :draft} ->
        announce(ledger, key, observation, opts)

      {false, nil} ->
        classify_from_history(ledger, key, observation, opts)

      {false, {:history_failed, _retry_at_ms}} ->
        classify_from_history(ledger, key, observation, opts)

      {false, _announced_or_never_draft} ->
        ledger
    end
  end

  defp apply_observation(ledger, _observation, _opts), do: ledger

  defp classify_from_history(ledger, key, observation, opts) do
    case Map.get(observation, :was_draft?) do
      true ->
        announce(ledger, key, observation, opts)

      false ->
        Map.put(ledger, key, :never_draft)

      :error ->
        now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
        Map.put(ledger, key, {:history_failed, now_ms + @history_retry_ms})

      _not_read ->
        ledger
    end
  end

  defp announce(ledger, {ticket, pr_number} = key, %{head_sha: head_sha}, opts) do
    repo_fun = Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0)

    case repo_fun.() do
      repo when is_binary(repo) and repo != "" ->
        Publisher.publish(
          "ticket.#{ticket}.pr.ready_for_review",
          %{action: "ready_for_review", pr: %{"number" => pr_number, "head" => %{"sha" => head_sha}, "draft" => false}},
          issue_number: ticket,
          dedup_key: GithubKeys.pr_dedup_key(repo, pr_number, "ready_for_review", head_sha)
        )

        Map.put(ledger, key, {:announced, head_sha})

      _no_repo ->
        ledger
    end
  end

  defp prune(ledger) when map_size(ledger) <= @max_entries, do: ledger

  defp prune(ledger) do
    ledger
    |> Enum.sort_by(fn {{_ticket, pr_number}, _entry} -> pr_number end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end
end
