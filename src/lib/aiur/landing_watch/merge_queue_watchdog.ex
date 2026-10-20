defmodule Aiur.LandingWatch.MergeQueueWatchdog do
  @moduledoc "Repairs queue entries that stay unmergeable despite a clean, ready PR."

  alias Aiur.Alerts
  alias Aiur.GitHub.{CiReadiness, Client, Transport}
  alias Aiur.LandingWatch.{Classifier, Journal, LocalRead}
  alias Aiur.PrMerge.Queue

  @threshold_ms 5 * 60_000
  @max_attempts 2

  @spec reconcile([map()], keyword()) :: :ok | {:error, term()}
  def reconcile(observations, opts) do
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      case reconcile_one(observation, now, opts) do
        {:error, _} = error -> {:halt, error}
        _ -> {:cont, :ok}
      end
    end)
  end

  @spec after_reconcile(:ok | {:error, term()}, :ok | {:error, term()}, [map()], keyword()) ::
          :ok | {:error, term()}
  def after_reconcile({:error, _} = error, _reconcile, _observations, _opts), do: error
  def after_reconcile(:ok, {:error, _} = error, _observations, _opts), do: error

  def after_reconcile(:ok, :ok, observations, opts) do
    Keyword.get(opts, :merge_queue_watchdog_fun, &__MODULE__.reconcile/2).(observations, opts)
  end

  defp reconcile_one(
         %{
           number: number,
           head: head,
           mergeable: "MERGEABLE",
           merge_state_status: "CLEAN",
           merge_queue_entry: %{"id" => entry, "state" => "UNMERGEABLE"}
         } = observation,
         now,
         opts
       )
       when is_integer(number) and is_binary(head) and is_binary(entry) do
    key = "#{number}:#{head}"

    with {:ok, row} <- reserve_first_seen(key, now, opts),
         :ok <- maybe_repair(observation, row, now, opts) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp reconcile_one(%{number: number, head: head}, _now, opts)
       when is_integer(number) and is_binary(head),
       do: clear_first_seen(number, head, opts)

  defp reconcile_one(_, _, _), do: :ok

  defp reserve_first_seen(key, now, opts) do
    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})

      existing =
        case Map.get(rows, key) do
          row when is_map(row) -> row
          since when is_integer(since) -> %{"since" => since, "attempts" => 0}
          _ -> %{"attempts" => 0}
        end

      row = Map.put(existing, "since", Map.get(existing, "since") || now)
      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, row)), row}
    end)
  end

  defp maybe_repair(observation, row, now, opts) do
    cond do
      not is_integer(row_since(row)) or now - row_since(row) < @threshold_ms ->
        :ok

      row_attempts(row) >= @max_attempts ->
        maybe_give_up(observation, row, opts)

      not observation_eligible?(observation) ->
        :ok

      true ->
        with :ok <- required_checks_pass?(observation, opts),
             :ok <- repair(observation, opts) do
          {:ok, _updated} = increment_attempt(observation.number, observation.head, opts)
          emit_attention(observation.number, observation.head, opts)

          :ok
        else
          {:skip, reason} ->
            log_skip(observation, reason)
            :ok

          {:error, :required_check_failed} = error ->
            log_skip(observation, elem(error, 1))
            :ok

          {:error, reason} ->
            log_skip(observation, reason)
            {:error, reason}
        end
    end
  end

  defp row_since(%{"since" => since}) when is_integer(since), do: since
  defp row_since(since) when is_integer(since), do: since
  defp row_since(_), do: 0

  defp row_attempts(%{"attempts" => attempts}) when is_integer(attempts), do: attempts
  defp row_attempts(_), do: 0

  defp observation_eligible?(observation),
    do:
      Map.get(observation, :draft?) == false and
        Map.get(observation, :review_decision) == "APPROVED" and
        is_nil(Map.get(observation, :auto_merge_request))

  defp increment_attempt(number, head, opts) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key, %{"since" => 0, "attempts" => 0})
      updated = Map.update(row, "attempts", 1, &(&1 + 1))
      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, updated)), updated}
    end)
  end

  defp maybe_give_up(observation, row, opts) do
    if row_attempts(row) == @max_attempts and not Map.get(row, "gave_up_alerted", false) do
      emit_gave_up(observation.number, observation.head, opts)
      mark_gave_up_alerted(observation.number, observation.head, opts)
      :ok
    else
      :ok
    end
  end

  defp clear_first_seen(number, head, opts) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key)

      rows =
        case row do
          value when is_map(value) -> Map.put(rows, key, Map.put(value, "since", nil))
          since when is_integer(since) -> Map.put(rows, key, %{"since" => nil, "attempts" => 0})
          _ -> rows
        end

      {:ok, Map.put(state, "unmergeable_queue_entries", rows)}
    end)
  end

  defp mark_gave_up_alerted(number, head, opts) do
    key = "#{number}:#{head}"

    Journal.update(opts, fn state ->
      rows = Map.get(state, "unmergeable_queue_entries", %{})
      row = Map.get(rows, key, %{}) |> Map.put("gave_up_alerted", true)
      {:ok, Map.put(state, "unmergeable_queue_entries", Map.put(rows, key, row))}
    end)
  end

  defp required_checks_pass?(observation, opts) do
    checks = Keyword.get(opts, :required_checks_snapshot, :not_fetched)

    checks =
      if checks == :not_fetched,
        do:
          LocalRead.run(
            Keyword.get(opts, :required_checks_fun, &CiReadiness.fetch_required_checks/1),
            [opts],
            opts
          ),
        else: checks

    with {:ok, checks} when is_list(checks) and checks != [] <- checks,
         {:ok, %{check_runs: runs, commit_status: status}} <-
           LocalRead.run(
             Keyword.get(opts, :ci_status_fun, &Client.fetch_commit_ci_status/2),
             [observation.head, opts],
             opts
           ),
         true <- checks_passed?(checks, runs, status, observation.head) do
      :ok
    else
      false -> {:error, :required_check_failed}
      {:error, _} = error -> error
      _ -> {:error, :required_check_failed}
    end
  end

  defp checks_passed?(checks, runs, status, head) do
    Classifier.ci_verdict(runs, status, %{"head" => %{"sha" => head}, "draft" => false}, required_checks: {:ok, checks}).decision == :passed
  end

  defp repair(observation, opts) do
    with true <-
           observation.draft? == false and observation.review_decision == "APPROVED" and
             observation.auto_merge_request == nil,
         :ok <- revalidate_queue_entry(observation, opts),
         :ok <- dequeue(observation.node_id, opts),
         :ok <- revalidate_eligible(%{observation | merge_queue_entry: nil}, opts),
         {:ok, _entry} <- enqueue(observation, opts) do
      :ok
    else
      false -> {:skip, :queue_recovery_observation_ineligible}
      {:error, _} = error -> error
      _ -> {:skip, :queue_recovery_precondition_changed}
    end
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

  defp emit_attention(number, head, opts) do
    message =
      "Merge queue entry for PR ##{number} stayed UNMERGEABLE for over five minutes while the PR is MERGEABLE/CLEAN and required checks pass; the entry was re-enqueued."

    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovered",
      central: true,
      durable: true,
      needs_attention: true,
      message: message,
      reason: "stale_unmergeable_entry",
      head: head
    )
  end

  defp emit_gave_up(number, head, opts) do
    Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2).(
      "system.pr.landing.merge_queue_recovery_gave_up",
      central: true,
      durable: true,
      needs_attention: true,
      message: "Merge queue recovery for PR ##{number} reached #{@max_attempts} attempts; automatic retries stopped.",
      reason: "merge_queue_recovery_attempt_limit",
      head: head
    )
  end

  defp log_skip(observation, reason) do
    require Logger

    Logger.info("merge queue watchdog skipped PR ##{observation.number} head=#{observation.head} reason=#{inspect(reason)}")
  end
end
