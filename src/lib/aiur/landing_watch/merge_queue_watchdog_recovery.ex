defmodule Aiur.LandingWatch.MergeQueueWatchdogRecovery do
  @moduledoc false

  alias Aiur.Alerts
  alias Aiur.GitHub.Transport
  alias Aiur.LandingWatch.Classifier
  alias Aiur.LandingWatch.MergeQueueRecoveryAttempt
  alias Aiur.PrMerge.Queue

  @doc false
  @spec repair(map(), keyword()) :: :ok | {:skip, term()} | {:error, term()}
  def repair(observation, opts) do
    with true <-
           observation.draft? == false and observation.review_decision == "APPROVED" and
             observation.auto_merge_request == nil,
         :ok <- revalidate_queue_entry(observation, opts),
         :ok <- dequeue(observation.node_id, opts) do
      revalidation_result = revalidate_eligible(%{observation | merge_queue_entry: nil}, opts)
      commit_result = commit_dequeued_attempt(observation, opts)

      enqueue_after_dequeue(observation, commit_result, revalidation_result, opts)
    else
      false -> {:skip, :queue_recovery_observation_ineligible}
      {:error, _} = error -> error
      _ -> {:skip, :queue_recovery_precondition_changed}
    end
  end

  defp enqueue_after_dequeue(observation, commit_result, revalidation_result, opts) do
    case enqueue(observation, opts) do
      {:ok, _entry} ->
        if match?({:error, _}, commit_result), do: emit_attempt_attention(observation.number, opts)
        if revalidation_result != :ok, do: emit_revalidation_attention(observation.number, opts)
        :ok

      {:error, reason} = error ->
        emit_enqueue_attention(observation.number, opts, inspect(reason))
        error
    end
  end

  defp emit_revalidation_attention(number, opts) do
    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovery_revalidation_changed",
      central: true,
      durable: true,
      needs_attention: true,
      message: "PR ##{number} was re-enqueued after its post-dequeue eligibility check changed.",
      reason: "merge_queue_recovery_revalidation_changed"
    )
  end

  defp commit_dequeued_attempt(observation, opts) do
    case Keyword.get(opts, :recovery_attempt_commit_fun, &MergeQueueRecoveryAttempt.commit/3).(
           observation.number,
           observation.head,
           opts
         ) do
      {:ok, _committed} -> :ok
      {:error, reason} -> {:error, {:attempt_commit_after_dequeue, reason}}
    end
  end

  defp emit_enqueue_attention(number, opts, detail) do
    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovery_enqueue_failed",
      central: true,
      durable: true,
      needs_attention: true,
      message: "Merge queue recovery dequeued PR ##{number} but could not confirm re-enqueue: #{detail}.",
      reason: "merge_queue_recovery_enqueue_failed"
    )
  end

  defp emit_attempt_attention(number, opts) do
    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovery_attempt_commit_failed",
      central: true,
      durable: true,
      needs_attention: true,
      message: "PR ##{number} was re-enqueued after dequeue, but the recovery attempt could not be persisted.",
      reason: "merge_queue_recovery_attempt_commit_failed"
    )
  end

  defp revalidate_eligible(observation, opts) do
    case Keyword.get(opts, :queue_recovery_revalidate_fun, &revalidate_live_entry/3).(
           observation.number,
           observation.head,
           opts
         ) do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:skip, :queue_recovery_precondition_changed}
    end
  end

  defp revalidate_live_entry(number, expected_head, opts) do
    query =
      "query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id headRefOid isDraft reviewDecision mergeable mergeStateStatus autoMergeRequest{enabledAt} mergeQueueEntry{id} reviews(states:APPROVED,last:1){nodes{commit{oid}}}}}}"

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, response} <-
           Transport.github_graphql(
             Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
             token,
             query,
             %{owner: owner, repo: repo, number: number},
             caller: "landing_watch_unmergeable_revalidate"
           ) do
      case response do
        %{"data" => %{"repository" => %{"pullRequest" => pr}}} ->
          validate_live_pr(pr, expected_head)

        _ ->
          {:error, :invalid_queue_recovery_revalidation}
      end
    end
  end

  defp validate_live_pr(pr, expected_head) do
    eligible? =
      pr["headRefOid"] == expected_head and pr["isDraft"] == false and
        pr["mergeable"] == "MERGEABLE" and pr["mergeStateStatus"] == "CLEAN" and
        is_nil(pr["mergeQueueEntry"]) and is_nil(pr["autoMergeRequest"]) and
        Classifier.approved_at_head?(pr)

    if eligible?, do: :ok, else: {:skip, :queue_recovery_precondition_changed}
  end

  defp revalidate_queue_entry(observation, opts) do
    case Keyword.get(opts, :revalidate_queue_fun) do
      fun when is_function(fun, 2) -> fun.(observation, opts)
      _ -> query_live_queue_entry(observation, opts)
    end
  end

  defp query_live_queue_entry(observation, opts) do
    with {:ok, pr} <- fetch_queue_revalidation_pr(observation.number, opts),
         true <- queue_entry_unchanged?(pr, observation) do
      :ok
    else
      {:error, _} = error -> error
      false -> {:skip, :queue_recovery_precondition_changed}
    end
  end

  defp fetch_queue_revalidation_pr(number, opts) do
    query =
      "query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){id headRefOid isDraft reviewDecision mergeable mergeStateStatus autoMergeRequest{enabledAt} mergeQueueEntry{id state} reviews(states:APPROVED,last:1){nodes{commit{oid}}}}}}"

    with {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, %{"data" => %{"repository" => %{"pullRequest" => pr}}}} <-
           Transport.github_graphql(
             Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
             token,
             query,
             %{owner: owner, repo: repo, number: number},
             caller: "landing_watch_unmergeable_revalidate"
           ) do
      {:ok, pr}
    end
  end

  defp queue_entry_unchanged?(pr, observation) do
    same_pull_request_head?(pr, observation) and clean_approved_pr?(pr) and
      same_unmergeable_entry?(pr, observation) and Classifier.approved_at_head?(pr)
  end

  defp same_pull_request_head?(pr, observation),
    do: pr["id"] == observation.node_id and pr["headRefOid"] == observation.head

  defp clean_approved_pr?(pr),
    do:
      pr["isDraft"] == false and pr["reviewDecision"] == "APPROVED" and
        pr["mergeable"] == "MERGEABLE" and pr["mergeStateStatus"] == "CLEAN" and
        is_nil(pr["autoMergeRequest"])

  defp same_unmergeable_entry?(pr, observation),
    do:
      get_in(pr, ["mergeQueueEntry", "id"]) == get_in(observation, [:merge_queue_entry, "id"]) and
        get_in(pr, ["mergeQueueEntry", "state"]) == "UNMERGEABLE"

  defp dequeue(node_id, opts) do
    api = graphql_api(opts, "landing_watch_unmergeable_dequeue")

    query =
      "mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { mergeQueueEntry { id } } }"

    case api.("post", "graphql", %{query: query, variables: %{id: node_id}}) do
      {:ok, %{"data" => %{"dequeuePullRequest" => %{}}}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :dequeue_unconfirmed}
    end
  end

  defp enqueue(observation, opts) do
    Queue.enqueue(graphql_api(opts, "landing_watch_unmergeable_enqueue"), %{
      node_id: observation.node_id,
      head: observation.head
    })
  end

  defp graphql_api(opts, caller) do
    fn "post", "graphql", %{query: query, variables: variables} ->
      with {:ok, token} <- Transport.require_token(opts),
           do:
             Transport.github_graphql(
               Keyword.get(opts, :request_fun, &Transport.default_request_fun/1),
               token,
               query,
               variables,
               caller: caller
             )
    end
  end
end
