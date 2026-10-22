defmodule Aiur.LandingWatch.MergeGroupRequeue do
  @moduledoc "Safely requeues approved PRs after non-PR merge-group failures."
  alias Aiur.GitHub.{Client, Transport}
  alias Aiur.LandingWatch.{Attribution, Classifier, Journal, Observer}
  alias Aiur.PrMerge.Queue

  @spec requeue_group_prs([pos_integer()], [map()], map(), String.t(), keyword()) :: :ok | {:error, term()}
  def requeue_group_prs(numbers, observations, run, reason, opts) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    identity = "merge-group-requeue-#{run["id"]}"

    Enum.reduce_while(numbers, :ok, fn number, result ->
      requeue_number(number, result, observations, run, reason, identity, now, opts)
    end)
  end

  defp requeue_number(
         _number,
         {:error, _} = error,
         _observations,
         _run,
         _reason,
         _identity,
         _now,
         _opts
       ),
       do: {:halt, error}

  defp requeue_number(number, :ok, observations, run, reason, identity, now, opts) do
    case Enum.find(observations, &(&1.number == number)) do
      nil -> {:cont, :ok}
      pr -> requeue_observed_pr(pr, number, run, reason, identity, now, opts)
    end
  end

  defp requeue_observed_pr(pr, number, run, reason, identity, now, opts) do
    if eligible_for_group_requeue?(pr, opts) do
      reserve_and_enqueue(pr, number, run, reason, identity, now, opts)
    else
      {:cont, :ok}
    end
  end

  defp reserve_and_enqueue(pr, number, run, reason, identity, now, opts) do
    case Journal.claim_alert(number, pr.head, identity, opts) do
      {:ok, :already_claimed} -> {:cont, :ok}
      {:ok, :new} -> requeue_claimed_pr(pr, number, run, reason, identity, now, opts)
      {:error, _} = error -> {:halt, error}
    end
  end

  defp requeue_claimed_pr(pr, number, run, reason, identity, now, opts) do
    case Journal.reserve_merge_group_requeue(now, opts) do
      :ok ->
        enqueue_and_comment(pr, number, run, reason, identity, opts)

      {:error, :merge_group_requeue_limit_reached} ->
        release_claim(number, pr.head, identity, opts, :ok)

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp enqueue_and_comment(pr, number, run, reason, identity, opts) do
    case enqueue_after_recovery(pr, opts) do
      {:ok, entry} -> confirm_requeue(pr, entry, number, run, reason, identity, opts)
      {:skip, _reason} -> release_claim(number, pr.head, identity, opts, :ok)
      {:error, _} = error -> release_claim(number, pr.head, identity, opts, error)
    end
  end

  defp enqueue_after_recovery(%{merge_queue_entry: %{"id" => entry, "state" => "UNMERGEABLE"}} = pr, opts)
       when is_binary(entry) do
    with :ok <- revalidate_unmergeable(pr, opts),
         :ok <- dequeue(pr.node_id, opts),
         :ok <- revalidate_queue_free(pr, opts) do
      enqueue(pr, pr.node_id, pr.head, opts)
    end
  end

  defp enqueue_after_recovery(pr, opts), do: enqueue(pr, pr.node_id, pr.head, opts)

  defp confirm_requeue(pr, entry, number, run, reason, identity, opts) do
    case Journal.mark_landed(pr.number, pr.head, entry, opts) do
      :ok ->
        case comment_requeue(pr, run, reason, opts) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {:error, _} = error ->
        release_claim(number, pr.head, identity, opts, error)
    end
  end

  defp release_claim(number, head, identity, opts, result) do
    _ = Journal.release_alert(number, head, identity, opts)

    case result do
      :ok -> {:halt, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp eligible_for_group_requeue?(
         %{number: number, head: head, merge_queue_entry: nil, auto_merge_request: nil} = pr,
         opts
       ) do
    eligible_approved_pr?(pr, number, head, opts) and
      Keyword.get(opts, :revalidate_fun, &Observer.revalidate_approved_head/3).(number, head, opts) == :ok
  end

  defp eligible_for_group_requeue?(
         %{number: number, head: head, node_id: node_id, merge_queue_entry: %{"id" => entry, "state" => "UNMERGEABLE"}} = pr,
         opts
       ) do
    eligible_approved_pr?(pr, number, head, opts) and is_binary(node_id) and is_binary(entry) and
      pr.mergeable == "MERGEABLE" and pr.merge_state_status == "CLEAN" and
      is_nil(pr.auto_merge_request)
  end

  defp eligible_for_group_requeue?(_pr, _opts), do: false

  defp eligible_approved_pr?(pr, number, head, opts) do
    pr.draft? == false and pr.review_decision == "APPROVED" and is_binary(head) and
      is_binary(pr.node_id) and approved?(number, opts) and attributed_cleanly?(pr, opts)
  end

  defp approved?(number, opts), do: Keyword.get(opts, :approved_fun, fn _, _ -> {:ok, true} end).(number, opts) == {:ok, true}

  defp attributed_cleanly?(pr, opts) do
    Keyword.get(opts, :attribution_fun, fn ticket -> Attribution.pull_request_clean?(ticket.number, opts) end).(pr) == {:ok, :clean}
  end

  defp revalidate_unmergeable(pr, opts) do
    Keyword.get(opts, :unmergeable_revalidate_fun, &query_unmergeable/2).(pr, opts)
  end

  defp revalidate_queue_free(pr, opts) do
    Keyword.get(opts, :queue_free_revalidate_fun, &query_queue_free/2).(pr, opts)
  end

  defp query_unmergeable(pr, opts), do: query_queue_state(pr, "UNMERGEABLE", opts)
  defp query_queue_free(pr, opts), do: query_queue_state(pr, nil, opts)

  defp query_queue_state(pr, expected_state, opts) do
    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, response} <- queue_state_response(owner, repo, pr.number, token, opts) do
      if queue_state_valid?(response, pr, expected_state), do: :ok, else: {:skip, :queue_recovery_precondition_changed}
    end
  end

  defp queue_state_response(owner, repo, number, token, opts) do
    query =
      "query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id headRefOid isDraft reviewDecision mergeable mergeStateStatus autoMergeRequest{enabledAt} mergeQueueEntry{id state} reviews(states:APPROVED,last:1){nodes{commit{oid}}}}}}"

    Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, query, %{owner: owner, repo: repo, number: number}, caller: "landing_watch_merge_group_requeue")
  end

  defp queue_state_valid?(response, pr, expected_state) do
    live = get_in(response, ["data", "repository", "pullRequest"])

    is_map(live) and matching_queue_pr?(live, pr) and queue_pr_approved_and_clean?(live) and
      matches_queue_state?(live, expected_state)
  end

  defp matching_queue_pr?(live, pr), do: live["id"] == pr.node_id and live["headRefOid"] == pr.head

  defp queue_pr_approved_and_clean?(live) do
    live["isDraft"] == false and live["reviewDecision"] == "APPROVED" and
      live["mergeable"] == "MERGEABLE" and live["mergeStateStatus"] == "CLEAN" and
      is_nil(live["autoMergeRequest"]) and Classifier.approved_at_head?(live)
  end

  defp matches_queue_state?(live, expected_state) do
    case {expected_state, live["mergeQueueEntry"]} do
      {nil, nil} -> true
      {state, %{"state" => state}} when is_binary(state) -> true
      _ -> false
    end
  end

  defp dequeue(node_id, opts) do
    case Keyword.get(opts, :dequeue_fun) do
      fun when is_function(fun, 2) ->
        fun.(node_id, opts)

      _ ->
        dequeue_with_github(node_id, opts)
    end
  end

  defp dequeue_with_github(node_id, opts) do
    query = "mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { mergeQueueEntry { id } } }"

    with {:ok, token} <- Transport.require_token(opts),
         {:ok, result} <- Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, query, %{id: node_id}, caller: "landing_watch_merge_group_requeue"),
         %{"data" => %{"dequeuePullRequest" => %{}}} <- result do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :dequeue_unconfirmed}
    end
  end

  defp comment_requeue(pr, run, reason, opts) do
    body =
      "Landing watcher requeued this approved PR after merge group run ##{run["id"]} failed due to #{reason}."

    Keyword.get(opts, :comment_fun, fn number, text, options ->
      Client.create_comment(to_string(number), text, options)
    end).(pr.number, body, opts)
  end

  defp enqueue(_pr, node_id, head, opts) do
    case Keyword.get(opts, :enqueue_fun) do
      fun when is_function(fun, 3) -> fun.(node_id, head, opts)
      _ -> enqueue_with_github(node_id, head, opts)
    end
  end

  defp enqueue_with_github(node_id, head, opts) do
    api = fn "post", "graphql", %{query: query, variables: variables} ->
      with {:ok, token} <- Transport.require_token(opts),
           do:
             Transport.github_graphql(
               Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
               token,
               query,
               variables,
               caller: "landing_watch_merge_group_requeue"
             )
    end

    Queue.enqueue(api, %{node_id: node_id, head: head})
  end
end
