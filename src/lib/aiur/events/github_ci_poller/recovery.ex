defmodule Aiur.Events.GithubCIPoller.Recovery do
  @moduledoc "One exact-head rerun, then bounded CI/rework escalation."
  require Logger
  alias Aiur.{AlertFeed, Alerts, Config}
  alias Aiur.CI.FailureDigest
  alias Aiur.GitHub.{CIRecovery, PullRequests}
  alias Aiur.GitHub.CIRecoveryStore, as: Store

  @spec attention_hold?(map() | nil) :: boolean()
  def attention_hold?(%{recovery: reason}) when is_binary(reason), do: true

  def attention_hold?(_), do: false

  @spec complete(map(), map(), term(), keyword()) :: map()
  def complete(_issue, _result, recovered, opts) when is_map(recovered), do: Map.merge(recovered, %{ci_recovery_checked: true, ci_recovery_opts: opts})
  def complete(issue, result, error, opts), do: attention(issue, result, "worker_failed", error, opts)

  @spec recover(map(), map(), keyword()) :: map()
  def recover(issue, %{pending_reason: :ci_cancelled, pr_number: number, head_sha: sha} = result, opts)
      when is_integer(number) and is_binary(sha) do
    target = to_string(issue.identifier || issue.id)

    case Store.read(target, number, opts) do
      {:ok, %{"hold" => %{"sha" => ^sha} = hold}} -> hold_result(result, hold)
      {:ok, _entry} -> attention(issue, result, "rerun_skipped", "cancelled_run", opts)
      {:error, reason} -> attention(issue, result, "evidence_unavailable", reason, opts)
    end
  end

  def recover(issue, %{pr_number: number, head_sha: sha} = result, opts) when is_integer(number) and is_binary(sha) do
    target = to_string(issue.identifier || issue.id)

    case Store.read(target, number, opts) do
      {:ok, entry} -> recover_current(issue, result, entry, opts)
      {:error, reason} -> attention(issue, result, "evidence_unavailable", reason, opts)
    end
  end

  def recover(_issue, result, _opts), do: result

  # The batch snapshot can predate an auto-merge re-enable (#4672), so an
  # approved failure it reports as not landing is confirmed live before rework.
  # An approval recorded on an older head no longer approves this one.
  defp recover_current(issue, %{head_sha: sha} = result, entry, opts) do
    cond do
      get_in(entry, ["hold", "sha"]) == sha or not unconfirmed_approved_failure?(result) -> recover_entry(issue, result, entry, opts)
      entry["landing_hold"] == sha -> held(result, "approved_landing_pr")
      true -> refresh_approved_landing(issue, result, entry, opts)
    end
  end

  defp unconfirmed_approved_failure?(%{head_sha: sha} = result) do
    result[:decision] == :failed and result[:review_decision] == "APPROVED" and result[:approved_review_head_sha] in [nil, sha] and
      is_nil(result[:auto_merge_request]) and is_nil(result[:merge_queue_entry])
  end

  defp refresh_approved_landing(issue, %{pr_number: number} = result, entry, opts) do
    case Keyword.get(opts, :ci_recovery_observation) || CIRecovery.observe(number, opts) do
      {:ok, pr} -> classify_landing_pr(issue, result, entry, pr, opts)
      {:error, reason} -> attention(issue, result, "observation_unavailable", reason, opts)
    end
  end

  defp classify_landing_pr(issue, result, entry, pr, opts) do
    case fresh_landing_state(result, pr) do
      :landing -> hold_landing(issue, result, opts)
      :not_landing -> recover_entry(issue, result, entry, Keyword.put(opts, :ci_recovery_observation, {:ok, pr}))
      :changed_head -> held(result, "head_changed")
      :unknown -> attention(issue, result, "observation_unavailable", "landing_state_unknown", opts)
    end
  end

  # Cached per head so later polls skip the live read; it only applies while
  # the PR still reads approved. LandingWatch routes rework from its own live
  # read if the PR stops landing.
  defp hold_landing(issue, result, opts) do
    case update(issue, result, &Map.put(&1, "landing_hold", result.head_sha), opts) do
      {:ok, _entry} -> :ok
      {:error, error} -> Logger.warning("CI recovery journal unavailable: #{inspect(error)}")
    end

    held(result, "approved_landing_pr")
  end

  defp fresh_landing_state(result, pr) do
    cond do
      pr["state"] != "OPEN" or pr["headRefOid"] != result[:head_sha] -> :changed_head
      is_map(pr["autoMergeRequest"]) or is_map(pr["mergeQueueEntry"]) -> :landing
      Map.has_key?(pr, "autoMergeRequest") and Map.has_key?(pr, "mergeQueueEntry") -> :not_landing
      true -> :unknown
    end
  end

  defp recover_entry(_issue, %{head_sha: sha} = result, %{"hold" => %{"sha" => sha} = hold}, _opts),
    do: hold_result(result, hold)

  defp recover_entry(issue, %{head_sha: sha} = result, %{"limit_hold" => %{"sha" => held_sha, "retry_at" => retry_at}}, opts) do
    if sha == held_sha and now(opts) < retry_at do
      held(result, "rerun_limit")
    else
      case update(issue, result, &Map.delete(&1, "limit_hold"), opts) do
        {:ok, updated} -> recover_entry(issue, result, updated, opts)
        {:error, reason} -> attention(issue, result, "evidence_unavailable", reason, opts)
      end
    end
  end

  defp recover_entry(issue, result, entry, opts) do
    cond do
      not Keyword.get_lazy(opts, :ci_recovery_enabled, &Config.ci_recovery_enabled?/0) ->
        result

      entry["cycles"] >= 3 ->
        attention(issue, result, "loop", "#{entry["cycles"]} failed CI/rework cycles", opts)

      true ->
        case digest(result.head_sha, opts) do
          {:ok, digest} -> recover_failure(issue, Map.put(result, :ci_failure_digest, digest), entry, opts)
          {:error, reason} -> attention(issue, result, "evidence_unavailable", reason, opts)
        end
    end
  end

  defp digest(sha, opts), do: Keyword.get(opts, :ci_failure_digest, &FailureDigest.build/2).(sha, opts)

  defp recover_failure(issue, result, entry, opts) do
    if get_in(entry, ["heads", result.head_sha]) != nil or retryable?(result.ci_failure_digest, result.pr_number, opts) do
      case Keyword.get(opts, :ci_recovery_observation) || CIRecovery.observe(result.pr_number, opts) do
        {:ok, pr} -> choose_recovery(issue, result, entry, pr, opts)
        {:error, reason} -> attention(issue, result, "observation_unavailable", reason, opts)
      end
    else
      result
    end
  end

  defp choose_recovery(issue, result, entry, pr, opts) do
    cond do
      pr["state"] != "OPEN" or pr["headRefOid"] != result.head_sha ->
        held(result, "head_changed")

      pr["isDraft"] != false ->
        if pr["isDraft"] == true, do: attention(issue, result, "rerun_skipped", "draft_pr", opts), else: held(result, "pr_observation_unavailable")

      pr["reviewDecision"] == "CHANGES_REQUESTED" ->
        attention(issue, result, "rerun_skipped", "changes_requested", opts)

      not Map.has_key?(pr, "mergeQueueEntry") ->
        held(result, "queue_observation_unavailable")

      pr["mergeQueueEntry"] != nil ->
        held(result, "merge_queue")

      true ->
        rerun(issue, result, entry, opts)
    end
  end

  defp retryable?(%{flake_only: true}, _number, _opts), do: true

  defp retryable?(%{test_only: true, tests: tests, truncated: false}, number, opts) when is_list(tests) and tests != [] do
    case PullRequests.fetch_pull_request_changed_paths(number, opts) do
      {:ok, paths} ->
        Enum.all?(tests, &(&1.classification == :known_flake or outside_diff?(&1, paths)))

      {:error, reason} ->
        Logger.warning("CI recovery changed paths unavailable: pr=#{number} reason=#{inspect(reason)}")
        false
    end
  end

  defp retryable?(_, _, _), do: false
  defp outside_diff?(%{path: path}, paths) when is_binary(path) and path != "", do: path not in paths
  defp outside_diff?(_, _), do: false

  defp rerun(issue, result, entry, opts) do
    case get_in(entry, ["heads", result.head_sha]) do
      nil -> start_rerun(issue, result, opts)
      %{"error" => error} -> attention(issue, result, "rerun_failed", error, opts)
      %{"runs" => runs} = attempt -> observe_rerun(issue, result, runs, attempt, opts)
    end
  end

  defp start_rerun(issue, result, opts) do
    case failing_runs(result.ci_failure_digest.checks, result.head_sha, opts) do
      {:ok, runs} -> prepare_reruns(issue, result, runs, opts)
      {:error, reason} -> rerun_error(issue, result, "rerun_unavailable", reason, opts)
    end
  end

  defp prepare_reruns(issue, result, runs, opts) do
    if Enum.any?(runs, &(&1["conclusion"] == "cancelled")) do
      attention(issue, result, "rerun_skipped", "cancelled_run", opts)
    else
      case Store.reserve_reruns(
             Keyword.get(opts, :ci_recovery_poll_id, :standalone),
             length(runs),
             Config.ci_recovery_max_per_poll(),
             Config.ci_recovery_max_per_hour(),
             opts
           ) do
        :ok -> persist_and_request(issue, result, runs, opts)
        {:error, :poll_limit_reached} -> held(result, "rerun_limit")
        {:error, {:hour_limit_reached, retry_at}} -> defer_reruns(issue, result, retry_at, opts)
        {:error, :ticket_exceeds_rerun_limit} -> attention(issue, result, "rerun_skipped", "ticket_exceeds_limit", opts)
        {:error, reason} -> rerun_error(issue, result, "rerun_unavailable", reason, opts)
      end
    end
  end

  defp defer_reruns(issue, result, retry_at, opts) do
    hold = %{"sha" => result.head_sha, "retry_at" => retry_at}

    case update(issue, result, &Map.put(&1, "limit_hold", hold), opts) do
      {:ok, _entry} -> held(result, "rerun_limit")
      {:error, reason} -> rerun_error(issue, result, "rerun_unavailable", reason, opts)
    end
  end

  defp persist_and_request(issue, result, runs, opts) do
    attempt = %{"runs" => runs, "checks" => check_ids(result), "requested_at" => now(opts)}

    case update(issue, result, &put_in(&1, ["heads", result.head_sha], attempt), opts) do
      {:ok, _} -> request_reruns(issue, result, runs, opts)
      {:error, reason} -> rerun_error(issue, result, "rerun_unavailable", reason, opts)
    end
  end

  defp request_reruns(issue, result, runs, opts) do
    case Enum.reduce_while(runs, :ok, &rerun_request(&1, &2, opts)) do
      :ok ->
        held(result, "rerun_requested")

      {:error, reason} ->
        update(issue, result, &put_in(&1, ["heads", result.head_sha, "error"], inspect(reason)), opts)
        rerun_error(issue, result, "rerun_failed", reason, opts)
    end
  end

  defp rerun_request(run, :ok, opts) do
    case CIRecovery.rerun(run["id"], opts) do
      {:ok, _} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp failing_runs(checks, sha, opts) do
    ids = checks |> Enum.map(&run_id(&1.url)) |> Enum.uniq()

    if ids == [] or nil in ids do
      {:error, :missing_actions_run_identity}
    else
      Enum.reduce_while(ids, {:ok, []}, &read_run(&1, &2, sha, opts))
    end
  end

  defp read_run(id, {:ok, runs}, sha, opts) do
    case CIRecovery.read("/actions/runs/#{id}", opts) do
      {:ok, %{"head_sha" => ^sha, "run_attempt" => attempt, "status" => "completed", "conclusion" => conclusion}} when is_integer(attempt) and conclusion in ["failure", "timed_out", "cancelled"] ->
        {:cont, {:ok, runs ++ [%{"id" => id, "attempt" => attempt, "conclusion" => conclusion}]}}

      other ->
        {:halt, {:error, {:invalid_actions_run, id, other}}}
    end
  end

  defp run_id(url) when is_binary(url) do
    case Regex.run(~r{/actions/runs/(\d+)(?:/|$)}, url) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp run_id(_), do: nil

  defp observe_rerun(issue, result, runs, attempt, opts) do
    observations = Enum.map(runs, &CIRecovery.read("/actions/runs/#{&1["id"]}", opts))

    case Enum.find(observations, fn observation -> actions_denied?(observation) end) do
      {:error, reason} ->
        rerun_error(issue, result, "rerun_unavailable", reason, opts)

      nil ->
        if fresh_failures?(result, attempt) and Enum.zip(runs, observations) |> Enum.all?(&rerun_completed?(&1, result.head_sha)) do
          result
        else
          await_attempt(issue, result, attempt, "rerun", opts)
        end
    end
  end

  defp rerun_error(issue, result, kind, reason, opts) do
    mode = if actions_denied?(reason), do: "fallback", else: "hold"
    attention(issue, result, kind, reason, opts, mode)
  end

  defp actions_denied?({:error, reason}), do: actions_denied?(reason)
  defp actions_denied?({:invalid_actions_run, _id, observation}), do: actions_denied?(observation)
  defp actions_denied?({:github, _classification, %{status: status}}), do: status in [403, 404]
  defp actions_denied?(_), do: false

  defp fresh_failures?(result, attempt) do
    checks = result.ci_failure_digest.checks
    names = Enum.map(checks, & &1.name)

    checks != [] and Enum.all?(check_ids(result), &(&1 not in attempt["checks"])) and
      Enum.all?(result.failures, &(&1.name in names))
  end

  defp check_ids(result), do: result.ci_failure_digest.checks |> Enum.map(& &1.id) |> Enum.sort()

  defp rerun_completed?({run, {:ok, %{"head_sha" => sha, "status" => "completed", "run_attempt" => attempt}}}, sha), do: attempt > run["attempt"]
  defp rerun_completed?(_, _), do: false

  defp now(opts), do: Keyword.get(opts, :ci_recovery_now, System.system_time(:second))

  defp await_attempt(issue, result, %{"error" => error}, kind, opts), do: attention(issue, result, kind <> "_failed", error, opts)

  defp await_attempt(issue, result, attempt, kind, opts) do
    if now(opts) - attempt["requested_at"] >= 600,
      do: attention(issue, result, kind <> "_stuck", "No new head/workflow attempt within ten minutes", opts),
      else: held(result, kind <> "_pending")
  end

  @spec record_pass(map(), map(), keyword()) :: :ok | {:error, term()}
  def record_pass(issue, %{pr_number: number} = result, opts) when is_integer(number) do
    case update(issue, result, &(&1 |> Map.put("cycles", 0) |> Map.delete("last_cycle") |> Map.delete("hold") |> Map.delete("limit_hold") |> Map.put("attentions", [])), opts) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        attention(issue, result, "journal_failed", error, opts)
        {:error, error}
    end
  end

  def record_pass(_, _, _), do: :ok

  @spec record_failure(map(), map(), keyword()) :: :ok | {:error, term()}
  def record_failure(issue, result, opts) do
    token = result.head_sha <> ":" <> to_string(issue.updated_at)

    case update(issue, result, &count_cycle(&1, token), opts) do
      {:ok, entry} ->
        if entry["cycles"] >= 3, do: attention(issue, result, "loop", "#{entry["cycles"]} failed CI/rework cycles", opts)
        :ok

      {:error, error} ->
        attention(issue, result, "journal_failed", error, opts)
        {:error, error}
    end
  end

  defp count_cycle(entry, token) do
    if entry["last_cycle"] == token, do: entry, else: entry |> Map.put("last_cycle", token) |> Map.update!("cycles", &(&1 + 1))
  end

  defp update(issue, result, fun, opts), do: Store.update(to_string(issue.identifier || issue.id), result.pr_number, fun, opts)

  defp attention(issue, result, kind, reason, opts, mode \\ "hold") do
    tests = failure_names(result)
    hold = %{"sha" => result.head_sha, "reason" => kind, "tests" => tests, "mode" => mode}
    message = "PR ##{Map.get(result, :pr_number)} CI recovery #{kind}: #{inspect(reason)}. Failing tests/checks: #{tests}"
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

    case update(issue, result, &(&1 |> Map.put("hold", hold) |> Map.delete("limit_hold")), opts) do
      {:ok, entry} ->
        unless kind in Map.get(entry, "attentions", []), do: emit_attention(issue, result, kind, message, emitter, opts)
        hold_result(result, hold)

      {:error, error} ->
        Logger.warning("CI recovery journal unavailable: #{inspect(error)}")
        emit_attention(issue, result, "journal_failed", message, emitter, opts)
        held(result, kind)
    end
  end

  defp hold_result(result, %{"tests" => tests} = hold) do
    result = Map.put(result, :ci_recovery_tests, tests)
    if hold["mode"] == "fallback", do: Map.put(result, :recovery, nil), else: held(result, hold["reason"])
  end

  defp emit_attention(issue, result, kind, message, emitter, opts) do
    topic = "ticket.#{issue.identifier || issue.id}.pr.ci_recovery.#{kind}"

    if kind != "journal_failed" or AlertFeed.condition_state(topic, opts) != :firing do
      publish_attention(topic, issue, result, kind, message, emitter, opts)
    end
  end

  defp publish_attention(topic, issue, result, kind, message, emitter, opts) do
    case emitter.(topic, issue: issue, central: true, needs_attention: true, message: message, reason: message) do
      :ok -> update(issue, result, &Map.update(&1, "attentions", [kind], fn kinds -> Enum.uniq([kind | kinds]) end), opts)
      {:error, error} -> Logger.warning("CI recovery attention failed: #{inspect(error)}")
    end
  end

  defp failure_names(%{ci_recovery_tests: tests}) when is_binary(tests) and tests != "", do: tests
  defp failure_names(%{ci_failure_digest: %{tests: [_ | _] = tests}}), do: tests |> Enum.map(& &1.identity) |> Enum.uniq() |> Enum.join(", ")
  defp failure_names(result), do: result |> Map.get(:failures, []) |> Enum.map_join(", ", & &1.name)
  defp held(result, reason), do: result |> Map.put(:decision, :pending) |> Map.put(:pending_reason, :ci_recovery) |> Map.put(:recovery, reason)
end
