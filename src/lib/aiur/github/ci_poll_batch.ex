defmodule Aiur.GitHub.CIPollBatch do
  @moduledoc false

  require Logger

  alias Aiur.GitHub.{DeliveredPullRequest, MergeQueue, PollSnapshots, Transport}
  alias Aiur.TicketBranch

  # Up to two headRefName-keyed aliases per target (the generated
  # `aiur/<id>-<slug>` branch and the legacy `aiur/<id>` one) keeps every query
  # bounded by the requested targets instead of scanning the repository's open
  # PR list, while staying at or under 100 aliases per call.
  #
  # `@pull_requests_per_branch` is 2 rather than 5 because the connection has
  # exactly one consumer: `put_first_pull_request/3` reads `List.first/1` of it
  # and discards the rest, so the newest is the answer and the second slot is
  # margin.
  #
  # This is correctness-preserving but NOT semantics-preserving, and the
  # difference matters. GitHub permits one open pull request per head/*base*
  # pair, so three open pull requests on a single head branch is legal. At
  # `first: 5` that answer came back from GraphQL; at `first: 2` it trips
  # `pageInfo.hasNextPage` and `put_entry_result/4` fail-closes the target to
  # the REST fallback — every cycle, with a warning, and at a cost rather than
  # a saving. The answer stays correct; the path to it changes.
  #
  # That case is rare enough here to accept, but do not read this as free.
  #
  # `contexts(first: 100)` is deliberately NOT reduced. A smaller page would
  # mean a pull request with many check contexts falls out to the REST fallback
  # every cycle, and — measured against GitHub's own reported `rateLimit
  # { cost }` — this whole document costs **1 point per call**, not the ~510 a
  # naive nodes/100 estimate predicts. There is no budget to buy with that risk.
  #
  # A target whose pull request a **webhook delivery already identified**
  # (`Aiur.GitHub.DeliveredPullRequest`) contributes a single
  # `pullRequest(number:)` alias instead of up to two speculative
  # `pullRequests(headRefName:)` connections, and can no longer fall out to the
  # REST fan-out because a legacy-branch guess missed. Only the number comes
  # from the store: `statusCheckRollup`, `mergeable` and `reviewDecision` are
  # still asked of GitHub on every cycle, because a CI verdict served from a
  # cache at any age is precisely what `Aiur.GitHub.ReadCache.Policy` refuses.
  #
  # A target whose CI a **webhook check-run delivery already answered** is
  # dropped from the document entirely (#2310): `PollSnapshots.ci_contexts`
  # answers when a complete snapshot the poll established has been advanced by
  # a delivery on the same head within the delivery-fresh window — "deposited
  # since the last read". The batch entry is then served from the delivery,
  # never as a verdict. `GithubCIPoller` carries the served entry through as
  # inert and the lifecycle makes no transition on it, because a CI verdict is
  # never answered from a held body at any age (R10); the real verdict comes
  # from the next non-displaced read. An unknown or unmatched check-run id
  # marked the snapshot incomplete (`PollSnapshots.merge_check_run`), so
  # `ci_contexts` answers `:miss` and the target keeps its place in the
  # document: this displacement fails toward polling, which is the #2276 lesson.
  @targets_per_query 50
  @pull_requests_per_branch 2

  @spec fetch([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(targets, opts \\ []) when is_list(targets) do
    targets = targets |> Enum.map(&to_string/1) |> Enum.uniq()

    if targets == [] do
      {:ok, %{}}
    else
      do_fetch(targets, opts)
    end
  end

  defp do_fetch(targets, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts) do
      request_fun = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      repo_identity = owner <> "/" <> repo

      # Per-target displacement (#2310): a target a delivery answered is dropped
      # from the document entirely, so a cycle whose targets were all answered
      # issues zero GraphQL calls. `PollSnapshots.ci_contexts` answers `:miss`
      # for every state that must fetch — no snapshot, poll-written, not
      # complete, expired, or a delivery an unknown/unmatched id marked
      # incomplete — so those targets keep their normal place in the document.
      {delivered, to_fetch} =
        targets
        |> Enum.map(&{&1, PollSnapshots.ci_contexts(repo_identity, &1, opts)})
        |> Enum.split_with(fn {_target, contexts} -> contexts != :miss end)

      result =
        Map.new(delivered, fn {target, {:ok, %{"head_sha" => head_sha} = contexts}} ->
          {target, delivered_entry(target, owner, repo, opts, head_sha, Map.get(contexts, "check_runs", []))}
        end)

      fetch_remaining(to_fetch, request_fun, token, owner, repo, opts, result)
    end
  end

  # Every target's CI was answered by a delivery since the last read; there is
  # no document to write and nothing to ask GitHub.
  defp fetch_remaining([], _request_fun, _token, _owner, _repo, _opts, result), do: {:ok, result}

  defp fetch_remaining(to_fetch, request_fun, token, owner, repo, opts, result) do
    fetch_targets = Enum.map(to_fetch, &elem(&1, 0))
    started_at_ms = System.system_time(:millisecond)

    chunks =
      fetch_targets
      |> Enum.map(&target_entry(&1, owner, repo, opts, started_at_ms))
      |> Enum.chunk_every(@targets_per_query)

    warn_on_chunk_overflow(chunks, fetch_targets)

    Enum.reduce_while(chunks, {:ok, result}, fn chunk, {:ok, acc} ->
      reduce_ci_chunk(request_fun, token, owner, repo, chunk, acc)
    end)
  end

  defp warn_on_chunk_overflow(chunks, fetch_targets) do
    if length(chunks) > 1 do
      Logger.warning("Github CI GraphQL batch alias overflow: targets=#{length(fetch_targets)} calls=#{length(chunks)}")
    end
  end

  # The served batch entry for a displaced target. It carries no pull-request
  # rollup and no verdict fields — the poller passes it through as inert and the
  # lifecycle makes no transition on it (R10: a CI verdict is never answered
  # from a held body at any age). `pr_number` rides along from the
  # delivered-pull-request store when available so the lifecycle can name the
  # PR if a later real poll acts, and the delivered check runs are carried so
  # the served entry documents exactly what the delivery answered.
  defp delivered_entry(target, owner, repo, opts, head_sha, check_runs) do
    %{
      delivered: true,
      head_sha: head_sha,
      check_runs: check_runs,
      pr_number: DeliveredPullRequest.number_for_target(target, owner, repo, opts)
    }
  end

  defp reduce_ci_chunk(request_fun, token, owner, repo, chunk, acc) do
    case fetch_chunk(request_fun, token, owner, repo, chunk) do
      {:ok, batch} -> {:cont, {:ok, Map.merge(acc, batch)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp target_entry(target, owner, repo, opts, started_at_ms) do
    entry =
      case DeliveredPullRequest.number_for_target(target, owner, repo, opts) do
        number when is_integer(number) -> %{target: target, pull_request_number: number, known_branch: true}
        nil -> branch_target_entry(target, opts)
      end

    Map.merge(entry, %{owner: owner, repo: repo, started_at_ms: started_at_ms})
  end

  defp branch_target_entry(target, opts) do
    case known_branch(target, opts) do
      nil -> %{target: target, branches: guessed_branches(target, opts), known_branch: false}
      branch -> %{target: target, branches: [branch], known_branch: true}
    end
  end

  # GitHub issues carry no branch name (`Issues.normalize_issue/5` sets
  # `branch_name: nil`), so without the title-derived candidate every target
  # would guess the legacy `aiur/<id>` branch, miss the real
  # `aiur/<id>-<slug>` one, and fall back to the full REST fan-out — paying a
  # GraphQL call on top of the reads this batch exists to remove.
  defp guessed_branches(target, opts) do
    title = opts |> Keyword.get(:titles_by_target, %{}) |> Map.get(target)
    legacy = TicketBranch.legacy_branch_name(target)

    case TicketBranch.branch_name(target, title) do
      ^legacy -> [legacy]
      generated -> [generated, legacy]
    end
  end

  defp known_branch(target, opts) do
    branch =
      opts |> Keyword.get(:branch_names_by_target, %{}) |> Map.get(target) ||
        opts |> Keyword.get(:open_pull_requests_by_target, %{}) |> open_pull_request_head_ref(target)

    if is_binary(branch) and branch != "", do: branch, else: nil
  end

  defp open_pull_request_head_ref(%{} = open_pull_requests, target) do
    case Map.get(open_pull_requests, target) do
      %{} = pull_request -> get_in(pull_request, ["head", "ref"])
      _other -> nil
    end
  end

  defp open_pull_request_head_ref(_open_pull_requests, _target), do: nil

  defp fetch_chunk(request_fun, token, owner, repo, entries) do
    indexed = Enum.with_index(entries)

    case Transport.github_graphql(request_fun, token, query(indexed), %{"owner" => owner, "repo" => repo}, caller: :ci_poll_batch) do
      {:ok, body} ->
        case get_in(body, ["data", "repository"]) do
          %{} = repository -> {:ok, match_entries(indexed, repository)}
          _other -> {:error, :ci_poll_batch_missing}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(indexed) do
    aliases = Enum.map_join(indexed, "\n", fn {entry, index} -> branch_aliases(entry, index) end)

    """
    query AiurCIPollBatch($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        #{aliases}
      }
    }
    """
  end

  defp branch_aliases(%{pull_request_number: number} = entry, index) when is_integer(number) do
    """
    delivered_#{index}: pullRequest(number: #{number}) { #{pull_request_fields(entry)} }
    """
  end

  defp branch_aliases(%{branches: branches} = entry, index) do
    branches
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {branch, candidate} -> branch_alias(branch, entry, index, candidate) end)
  end

  defp branch_alias(branch, entry, index, candidate) do
    """
    branch_#{index}_#{candidate}: pullRequests(headRefName: "#{escape_graphql_string(branch)}", states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}, first: #{@pull_requests_per_branch}) {
      pageInfo { hasNextPage }
      nodes { #{pull_request_fields(entry)} }
    }
    """
  end

  defp pull_request_fields(_entry) do
    """
    number state headRefName headRefOid baseRefName
    isDraft reviewDecision mergeable mergeStateStatus
    autoMergeRequest { enabledAt }
    mergeQueueEntry { id }
    #{contexts_selection()}
    """
  end

  defp contexts_selection do
    """
    commits(last: 1) {
      nodes {
        commit {
          statusCheckRollup {
            contexts(first: 100) {
              pageInfo { hasNextPage endCursor }
              nodes {
                __typename
                ... on CheckRun { databaseId name status conclusion detailsUrl startedAt completedAt }
                ... on StatusContext { context state targetUrl createdAt description }
              }
            }
          }
        }
      }
    }
    """
  end

  defp escape_graphql_string(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  defp match_entries(indexed, repository) do
    Enum.reduce(indexed, %{}, fn {entry, index}, acc -> match_entry(acc, entry, repository, index) end)
  end

  # A delivery already named the pull request, so there is one alias and no
  # candidate list to choose between. A pull request GitHub now reports as
  # closed is left to the REST fallback rather than answered as "no open pull
  # request": closed is exactly the state in which a newer one may exist.
  defp match_entry(acc, %{pull_request_number: _number} = entry, repository, index) do
    case Map.get(repository, "delivered_#{index}") do
      %{"headRefName" => _ref} = node ->
        if open_pull_request_node?(node), do: put_first_pull_request(acc, entry, node), else: acc

      _other ->
        Logger.warning("Github CI GraphQL batch alias missing: target=#{entry.target}")
        acc
    end
  end

  defp match_entry(acc, entry, repository, index) do
    case candidate_connections(entry, repository, index) do
      {:ok, connections} ->
        match_candidates(acc, entry, connections)

      :missing ->
        Logger.warning("Github CI GraphQL batch alias missing: target=#{entry.target}")
        acc
    end
  end

  defp open_pull_request_node?(node), do: node |> Map.get("state") |> to_string() |> String.downcase() == "open"

  defp candidate_connections(entry, repository, index) do
    connections =
      entry.branches
      |> Enum.with_index()
      |> Enum.map(fn {_branch, candidate} -> Map.get(repository, "branch_#{index}_#{candidate}") end)

    if Enum.all?(connections, &match?(%{"nodes" => nodes} when is_list(nodes), &1)),
      do: {:ok, connections},
      else: :missing
  end

  # The first candidate branch that resolves to an open PR wins. Only when no
  # candidate matched does the "no open PR" answer stand — and then only for a
  # branch orchestration actually knows.
  defp match_candidates(acc, entry, connections) do
    case Enum.find(connections, fn %{"nodes" => nodes} -> nodes != [] end) do
      nil ->
        [connection | _rest] = connections
        put_entry_result(acc, entry, [], Map.get(connection, "pageInfo") || %{})

      connection ->
        put_entry_result(acc, entry, Map.get(connection, "nodes"), Map.get(connection, "pageInfo") || %{})
    end
  end

  defp put_entry_result(acc, entry, nodes, page_info) do
    if Map.get(page_info, "hasNextPage") == true do
      # More open PRs share the head branch than one page covers; leave the
      # target to REST fallback so the truncated listing is never trusted.
      Logger.warning("Github CI GraphQL batch overflow: head_ref_pull_requests target=#{entry.target}")
      acc
    else
      put_first_pull_request(acc, entry, List.first(nodes))
    end
  end

  # The legacy `aiur/<id>` branch guess found nothing. The ticket may use a
  # suffixed branch this cycle does not know, so leave the target to REST
  # fallback rather than claiming no PR exists.
  defp put_first_pull_request(acc, %{known_branch: false}, nil), do: acc

  defp put_first_pull_request(acc, entry, nil) do
    Map.put(acc, entry.target, %{pull_request: nil, check_runs: [], commit_status: empty_commit_status()})
  end

  defp put_first_pull_request(acc, entry, node) do
    result = normalize_pull_request(node)

    cond do
      Map.get(result, :contexts_overflow) ->
        Logger.warning("Github CI GraphQL batch overflow: status_contexts target=#{entry.target}")
        acc

      true ->
        PollSnapshots.put_ci_contexts(
          entry.owner <> "/" <> entry.repo,
          entry.target,
          get_in(result, [:pull_request, "head", "sha"]),
          result.check_runs,
          result.commit_status,
          started_at_ms: entry.started_at_ms
        )

        Map.put(acc, entry.target, result)
    end
  end

  defp normalize_pull_request(node) do
    {contexts, contexts_overflow} = get_in(node, ["commits", "nodes"]) |> List.wrap() |> List.last() |> status_contexts()
    {check_runs, statuses} = Enum.split_with(contexts, &(Map.get(&1, "__typename") == "CheckRun"))

    %{
      pull_request:
        %{
          "number" => Map.get(node, "number"),
          "state" => String.downcase(to_string(Map.get(node, "state", "open"))),
          "head" => %{"ref" => Map.get(node, "headRefName"), "sha" => Map.get(node, "headRefOid")},
          "base" => %{"ref" => Map.get(node, "baseRefName")}
        }
        |> put_merge_queue_observation(node),
      check_runs: Enum.map(check_runs, &normalize_check_run/1),
      commit_status: normalize_commit_status(statuses),
      contexts_overflow: contexts_overflow
    }
  end

  # The merge-queue recovery observation (ready/approved/mergeable/unarmed) is
  # derived from the same GraphQL node, so no extra read is needed. A node the
  # batch cannot fully observe simply carries no observation, which the
  # classifier treats as `:unknown` (fail closed) rather than arming or
  # clearing a recovery signal on partial data.
  defp put_merge_queue_observation(pull_request, node) do
    case MergeQueue.normalize_graphql_pull_request(node) do
      %{} = observation -> Map.put(pull_request, "merge_queue", observation)
      {:error, _reason} -> pull_request
    end
  end

  defp status_contexts(nil), do: {[], false}

  defp status_contexts(commit_node) when is_map(commit_node) do
    commit = Map.get(commit_node, "commit") || %{}

    case Map.fetch(commit, "status") do
      {:ok, %{"contexts" => statuses}} when is_list(statuses) ->
        {Enum.map(statuses, &Map.put(&1, "__typename", "StatusContext")), false}

      {:ok, _nil_or_malformed} ->
        {[], false}

      :error ->
        contexts = get_in(commit, ["statusCheckRollup", "contexts"]) || %{}
        {Map.get(contexts, "nodes", []), get_in(contexts, ["pageInfo", "hasNextPage"]) == true}
    end
  end

  defp status_contexts(_commit_node), do: {[], false}

  # Paired with `Aiur.Events.GithubWebhook.Deposit.normalize_check_run/1`, which
  # shapes the same run out of a REST delivery so the two merge into one
  # snapshot. The keys here are the contract between them: `"id"` must be the
  # numeric database id on both sides or the merge cannot join a delivery to the
  # polled baseline, and a key one side emits and the other omits silently
  # changes shape when a delivery overwrites a polled run. The one deliberate
  # asymmetry is `"updated_at"`, which only the delivery carries and which
  # `PollSnapshots.check_run_marker/1` uses to refuse a late delivery. Change
  # one, change both.
  defp normalize_check_run(check_run) do
    %{
      "id" => Map.get(check_run, "databaseId"),
      "name" => Map.get(check_run, "name"),
      "status" => Map.get(check_run, "status") |> to_string() |> String.downcase(),
      "conclusion" => check_run |> Map.get("conclusion") |> normalize_optional_string(),
      "started_at" => Map.get(check_run, "startedAt"),
      "completed_at" => Map.get(check_run, "completedAt"),
      "output" => Map.get(check_run, "output", %{})
    }
  end

  defp normalize_commit_status(statuses) do
    statuses =
      Enum.map(statuses, fn status ->
        %{
          "context" => Map.get(status, "context"),
          "state" => Map.get(status, "state") |> to_string() |> String.downcase(),
          "created_at" => Map.get(status, "createdAt"),
          "description" => Map.get(status, "description")
        }
      end)

    %{"statuses" => statuses, "state" => combined_state(statuses)}
  end

  defp empty_commit_status, do: %{"statuses" => [], "state" => ""}
  defp combined_state([]), do: ""

  defp combined_state(statuses) when is_list(statuses) do
    states = Enum.map(statuses, &Map.get(&1, "state"))

    cond do
      Enum.any?(states, &(&1 in ["error", "failure"])) -> "failure"
      Enum.all?(states, &(&1 == "success")) -> "success"
      true -> "pending"
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: value |> to_string() |> String.downcase()
end
