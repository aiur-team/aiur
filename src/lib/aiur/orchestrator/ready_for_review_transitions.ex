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
    * a ready observation at a new head publishes once for that head;
    * a ready observation of a PR the ledger does not know is resolved from the
      PR's history (`GitHub.Client.fetch_pull_request_was_draft/2`), which the
      comment poll reads once per such PR: a PR that was a draft publishes, and
      a PR opened ready records `:never_draft` and publishes nothing, as the
      webhook does. The CI poll does not read history, so it leaves an unknown
      PR for the comment poll.

  Each newly ready head therefore gets exactly one wake. The publish carries the webhook's dedup key
  (`GithubKeys.pr_dedup_key(repo, pr, "ready_for_review", head_sha)`), so a
  webhook delivery and a poll of the same transition produce one event.
  """

  alias Aiur.Config.AgentSettings
  alias Aiur.{Events, Events.GithubKeys}
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
          optional(:pr_author) => String.t() | nil,
          optional(:was_draft?) => boolean() | :error | nil,
          optional(:ready_at_ms) => integer() | nil
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
      |> maybe_put_author(get_in(pr, ["user", "login"]))
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

  @doc "Records a real webhook-observed draft-to-ready transition without publishing it again."
  @spec observe_webhook_transition(State.t(), String.t(), pos_integer(), String.t()) :: State.t()
  def observe_webhook_transition(%State{} = state, ticket, pr_number, head_sha)
      when is_binary(ticket) and ticket != "" and is_integer(pr_number) and pr_number > 0 and is_binary(head_sha) and head_sha != "" do
    ledger = ledger(state)
    next = Map.put(ledger, {ticket, pr_number}, {:announced, head_sha})

    if next != ledger do
      :ok = PrReadyLedgerStore.save(next)
    end

    %{state | pr_ready_ledger: next}
  end

  def observe_webhook_transition(%State{} = state, _ticket, _pr_number, _head_sha), do: state

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

  @doc false
  @spec announce_ci_ready(State.t(), String.t(), pos_integer(), String.t(), keyword()) :: State.t()
  def announce_ci_ready(%State{} = state, ticket, pr_number, head_sha, opts \\ []) do
    observation =
      observation(ticket, pr_number, head_sha, false)

    announce_ci_ready_observation(state, observation, opts)
  end

  defp announce_ci_ready_observation(state, nil, _opts), do: state

  defp announce_ci_ready_observation(state, observation, opts) do
    ticket = observation.ticket
    pr_number = observation.pr_number
    head_sha = observation.head_sha
    key = {ticket, pr_number}

    case Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0).() do
      repo when is_binary(repo) and repo != "" ->
        Events.publish(
          "ticket.#{ticket}.pr.ready_for_review",
          ready_payload(repo, pr_number, head_sha, observation, opts),
          issue_number: ticket,
          bypass_contamination: true,
          dedup_key: GithubKeys.pr_dedup_key(repo, pr_number, "ci_ready_for_review", head_sha)
        )

        ready_at_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
        update_entry(state, key, {:announced, head_sha, ready_at_ms, nil})

      _no_repo ->
        state
    end
  end

  @doc "Re-raises an aged ready PR when its current head is green and has no review."
  @spec re_raise_unreviewed(State.t(), observation(), map(), keyword()) :: State.t()
  def re_raise_unreviewed(state, observation, result, opts \\ [])

  def re_raise_unreviewed(%State{} = state, %{draft?: false, ticket: ticket, pr_number: pr_number, head_sha: head_sha, ready_at_ms: ready_at_ms}, result, opts) do
    key = {ticket, pr_number}
    state = record_ready_head(state, key, head_sha, ready_at_ms)
    ledger = ledger(state)
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    age_limit_ms = Keyword.get(opts, :age_limit_ms, age_limit_ms())

    with entry when not is_nil(entry) <- Map.get(ledger, key),
         {:ok, tracked_ready_at_ms, retry_at_ms} <- tracked_head(entry, head_sha),
         ready_at_ms when is_integer(ready_at_ms) <- ready_at_ms || tracked_ready_at_ms,
         true <- now_ms - ready_at_ms >= age_limit_ms,
         true <- is_nil(retry_at_ms) or now_ms >= retry_at_ms,
         true <- result[:decision] == :passed,
         # CHANGES_REQUESTED sticks until the next review, so a reworked head handed back still needs one.
         true <- result[:review_decision] in ["REVIEW_REQUIRED", "CHANGES_REQUESTED"],
         true <- result[:reviewed_head?] == false,
         {:ok, repo} <- repo_name(opts),
         :ok <- emit_stale_attention(ticket, pr_number, head_sha, now_ms - ready_at_ms, repo, opts) do
      update_entry(state, key, {:announced, head_sha, ready_at_ms, now_ms + Keyword.get(opts, :backoff_ms, age_limit_ms)})
    else
      _ -> state
    end
  end

  def re_raise_unreviewed(%State{} = state, _observation, _result, _opts), do: state

  defp tracked_head({:announced, head_sha, ready_at_ms, retry_at_ms}, head_sha), do: {:ok, ready_at_ms, retry_at_ms}
  defp tracked_head({:announced, head_sha}, head_sha), do: {:ok, nil, nil}
  defp tracked_head(_, _head_sha), do: :error

  defp record_ready_head(state, key, head_sha, ready_at_ms) when is_integer(ready_at_ms) do
    case Map.get(ledger(state), key) do
      :never_draft -> update_entry(state, key, {:announced, head_sha, ready_at_ms, nil})
      _ -> state
    end
  end

  defp record_ready_head(state, _key, _head_sha, _ready_at_ms), do: state

  @spec age_limit_ms() :: pos_integer()
  def age_limit_ms do
    AgentSettings.unreviewed_pr_age_limit_minutes() * 60_000
  end

  defp repo_name(opts) do
    case Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0).() do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _ -> :error
    end
  end

  defp emit_stale_attention(ticket, pr_number, head_sha, age_ms, repo, opts) do
    message = "PR ##{pr_number} for ticket ##{ticket} has been ready and unreviewed for #{Float.round(age_ms / 3_600_000, 1)} hours (head #{head_sha})."
    emitter = Keyword.get(opts, :alert_emitter, &Aiur.Alerts.emit_system/2)

    emitter.("ticket.#{ticket}.agent.attention.unreviewed_ready_pr",
      issue: ticket,
      central: true,
      message: message,
      reason: message,
      needs_attention: true,
      exchange_payload: %{"pr_number" => pr_number, "head_sha" => head_sha, "age_ms" => age_ms, "repo" => repo}
    )
  end

  defp update_entry(state, key, entry) do
    next = Map.put(ledger(state), key, entry)
    :ok = PrReadyLedgerStore.save(next)
    %{state | pr_ready_ledger: next}
  end

  defp apply_observation(ledger, %{ticket: ticket, pr_number: pr_number, draft?: draft?} = observation, opts) do
    key = {ticket, pr_number}

    entry = Map.get(ledger, key)

    case {draft?, entry} do
      # The comment poll folds an observation taken when its task started, so
      # a stale draft reading can arrive after the CI poll already announced
      # the same head. The fold is monotonic for that head: only a draft at a
      # different head re-arms the PR. A real same-head re-draft loses nothing,
      # because its next ready would carry the announced dedup key anyway.
      {true, {:announced, head_sha}} ->
        stale_draft(ledger, key, observation.head_sha, head_sha)

      {true, {:announced, head_sha, _ready_at_ms, _retry_at_ms}} ->
        stale_draft(ledger, key, observation.head_sha, head_sha)

      {true, _entry} ->
        Map.put(ledger, key, :draft)

      {false, entry} ->
        apply_ready_observation(ledger, key, observation, opts, entry)
    end
  end

  defp apply_observation(ledger, _observation, _opts), do: ledger

  defp apply_ready_observation(ledger, key, observation, opts, :draft), do: announce(ledger, key, observation, opts)
  defp apply_ready_observation(ledger, key, observation, opts, nil), do: classify_from_history(ledger, key, observation, opts)
  defp apply_ready_observation(ledger, key, observation, opts, {:history_failed, _retry_at}), do: classify_from_history(ledger, key, observation, opts)

  defp apply_ready_observation(ledger, key, observation, _opts, :never_draft) do
    ready_at_ms = Map.get(observation, :ready_at_ms)
    if is_integer(ready_at_ms), do: Map.put(ledger, key, {:announced, observation.head_sha, ready_at_ms, nil}), else: ledger
  end

  defp apply_ready_observation(ledger, key, observation, opts, {:announced, prior_head, _, _}) when prior_head != observation.head_sha, do: announce(ledger, key, observation, opts)
  defp apply_ready_observation(ledger, key, observation, opts, {:announced, prior_head}) when prior_head != observation.head_sha, do: announce(ledger, key, observation, opts)

  defp apply_ready_observation(ledger, key, %{head_sha: head_sha} = observation, _opts, {:announced, head_sha}) do
    ready_at_ms = Map.get(observation, :ready_at_ms)
    if is_integer(ready_at_ms), do: Map.put(ledger, key, {:announced, head_sha, ready_at_ms, nil}), else: ledger
  end

  defp apply_ready_observation(ledger, key, %{head_sha: head_sha} = observation, _opts, {:announced, head_sha, prior_ready_at_ms, retry_at_ms}) do
    observed_ready_at_ms = Map.get(observation, :ready_at_ms)
    ready_at_ms = if is_integer(observed_ready_at_ms), do: min(prior_ready_at_ms, observed_ready_at_ms), else: prior_ready_at_ms
    Map.put(ledger, key, {:announced, head_sha, ready_at_ms, retry_at_ms})
  end

  defp apply_ready_observation(ledger, _key, _observation, _opts, _known), do: ledger

  defp stale_draft(ledger, key, observed_head, announced_head) do
    if announced_head == observed_head, do: ledger, else: Map.put(ledger, key, :draft)
  end

  defp classify_from_history(ledger, key, observation, opts) do
    case Map.get(observation, :was_draft?) do
      true ->
        announce(ledger, key, observation, Keyword.put(opts, :observation, "initial_sync"))

      false ->
        Map.put(ledger, key, :never_draft)

      :error ->
        now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
        Map.put(ledger, key, {:history_failed, now_ms + @history_retry_ms})

      _not_read ->
        ledger
    end
  end

  defp announce(ledger, {ticket, pr_number} = key, observation, opts) do
    repo_fun = Keyword.get(opts, :repo_fun, &GitHubConfig.repo/0)

    case repo_fun.() do
      repo when is_binary(repo) and repo != "" ->
        Events.publish(
          "ticket.#{ticket}.pr.ready_for_review",
          ready_payload(repo, pr_number, observation.head_sha, observation, opts),
          issue_number: ticket,
          # A ready PR is itself the wake signal for a parked ticket, which
          # may be absent from the active tracked set while it waits on CI.
          bypass_contamination: true,
          dedup_key: GithubKeys.pr_dedup_key(repo, pr_number, "ready_for_review", observation.head_sha)
        )

        ready_at_ms = Map.get(observation, :ready_at_ms) || System.system_time(:millisecond)
        Map.put(ledger, key, {:announced, observation.head_sha, ready_at_ms, nil})

      _no_repo ->
        ledger
    end
  end

  defp ready_payload(repo, pr_number, head_sha, observation, opts) do
    pr_author = Map.get(observation, :pr_author)
    pr = %{"number" => pr_number, "head" => %{"sha" => head_sha}, "draft" => false}

    pr =
      case GithubKeys.last_review_sha(repo, pr_number, pr_author) do
        sha when is_binary(sha) -> Map.put(pr, "last_review_sha", sha)
        _ -> pr
      end

    payload = %{action: "ready_for_review", pr: pr}

    case Keyword.get(opts, :observation) do
      "initial_sync" -> Map.put(payload, :observation, "initial_sync")
      _ -> payload
    end
  end

  defp maybe_put_author(observation, author) when is_map(observation) and is_binary(author),
    do: Map.put(observation, :pr_author, author)

  defp maybe_put_author(observation, _author), do: observation

  defp prune(ledger) when map_size(ledger) <= @max_entries, do: ledger

  defp prune(ledger) do
    ledger
    |> Enum.sort_by(fn {{_ticket, pr_number}, _entry} -> pr_number end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end
end
