defmodule Aiur.LandingWatch.PrRerun do
  @moduledoc """
  Reruns an approved, not-landing PR's failed CI when the failure has a non-PR
  cause, and routes PR-caused failures to rework.

  Each head action spends the per-head budget, and each workflow rerun spends
  one shared automatic-requeue slot in the journal. A head deferred by the
  shared cap stays in the journal's rerun backlog until a later poll reruns it.
  A head whose failure needs a fresh
  merge ref is never rerun; it gets GitHub's update-branch under the same budget
  and cap (#4930), unless the base changed the PR's own files; then it routes
  to rework so the worker retests the new head.
  """

  alias Aiur.GitHub.{CIRecovery, Client}
  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{Journal, MergeGroupJournal, MergeGroupRunFetcher, PrRerunClassifier}
  alias Aiur.TicketBranch

  @rerun_conclusions ["cancelled", "failure", "timed_out", "startup_failure"]
  @caller "landing_watch_pr_rerun"

  @doc false
  @spec recover_main_ci(map(), [map()], {integer(), integer()}, keyword()) :: :ok | {:error, term()}
  def recover_main_ci(observation, runs, {red_since, recovered_at}, opts) do
    failed =
      Enum.filter(runs, fn run ->
        started = timestamp_ms(run["started_at"])

        run["status"] == "completed" and run["conclusion"] in ["failure", "timed_out", "startup_failure"] and
          is_integer(started) and started >= red_since and started <= recovered_at
      end)

    cond do
      failed == [] ->
        :ok

      Enum.any?(failed, &PrRerunClassifier.stale_merge_ref?(&1, opts)) ->
        stale = Enum.filter(failed, &PrRerunClassifier.stale_merge_ref?(&1, opts))
        request_remedy(observation, stale, :refresh, "merge ref predates a fix on the base branch", opts)

      true ->
        request_remedy(observation, failed, :rerun, "main CI recovered", opts)
    end
  end

  @spec handle_failure(map(), map(), [map()], keyword()) :: :ok | {:error, term()}
  def handle_failure(observation, result, runs, opts) do
    with {:ok, state} <- Journal.state(opts) do
      marker = rework_marker(runs, state)
      entry = Map.get(state, "#{observation.number}:#{observation.head}", %{})
      pending = Map.get(entry, "rerun_pending", %{})
      github_opts = Keyword.put(opts, :caller, @caller)
      refusal = Journal.rerun_refusal(entry, now(opts))

      # Cached verdicts, a deferred remedy and a spent budget all skip the classifier's GitHub reads.
      cond do
        Map.has_key?(Map.get(entry, "alerts", %{}), marker) ->
          LandingWatch.rework(observation, result.failures, opts)

        refusal == :rerun_backoff ->
          :ok

        refusal == :rerun_limit_reached ->
          alert_limit(observation, opts)

        is_binary(pending["reason"]) ->
          pending_runs = pending_runs(runs, pending)
          pending_opts = Keyword.put(github_opts, :rerun_per_head_reserved, pending["per_head_reserved"] == true)
          remedy(observation, pending_runs, action(pending["action"]), pending["reason"], marker, pending_opts)

        true ->
          classify_and_route(observation, result, runs, marker, github_opts, opts)
      end
    end
  end

  # A rework verdict is cached per head, run set and latest CI merge, and a deferred head keeps its
  # reason, so later polls skip the log reads.
  defp rework_marker(runs, state) do
    run_ids = runs |> Enum.map(&to_string(&1["run_id"])) |> Enum.sort() |> Enum.join("-")
    latest_ci_merge = state |> Map.get("ci_merges", []) |> List.first() |> then(&(&1 && &1["pr"]))
    "rework-verdict-#{run_ids}-ci-#{latest_ci_merge}"
  end

  defp now(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_ms(_), do: nil

  defp classify_and_route(observation, result, runs, marker, github_opts, opts) do
    case Keyword.get(opts, :rerun_classifier_fun, &PrRerunClassifier.classify/4).(observation, result, runs, github_opts) do
      # A rerun reuses the old merge commit; only a fresh merge ref picks up the base fix.
      {:ok, {action, reason}} when action in [:rerun, :refresh] ->
        remedy(observation, runs, action, reason, marker, github_opts)

      {:ok, :rework} ->
        with {:ok, _} <- Journal.claim_alert(observation.number, observation.head, marker, opts),
             do: LandingWatch.rework(observation, result.failures, opts)

      {:error, _} = error ->
        error
    end
  end

  defp action("refresh"), do: :refresh
  defp action(_), do: :rerun

  defp pending_runs(runs, %{"run_ids" => ids}) when is_list(ids) do
    eligible = MapSet.new(ids)
    Enum.filter(runs, &MapSet.member?(eligible, Map.get(&1, "run_id")))
  end

  defp pending_runs(runs, _pending), do: runs

  defp remedy(observation, runs, :rerun, reason, _marker, opts), do: request_remedy(observation, runs, :rerun, reason, opts)

  # Base changes to the PR's own files void its Tested head (#4854), so the worker retests rather than the watcher updating.
  defp remedy(observation, runs, :refresh, reason, marker, opts) do
    overlap =
      case defer_if_refused(observation, runs, reason, opts) do
        :ok -> base_overlap(observation, opts)
        :deferred -> :ok
        {:error, _} = error -> error
      end

    case overlap do
      :ok ->
        :ok

      {:ok, []} ->
        request_remedy(observation, runs, :refresh, reason, opts)

      {:ok, paths} ->
        failure = %{name: "Base changed this PR's files", excerpt: "update the branch and rerun local tests at the new head (#{Enum.join(paths, ", ")})"}

        with :ok <- Journal.clear_rerun_pending(observation.number, observation.head, opts),
             {:ok, _} <- Journal.claim_alert(observation.number, observation.head, marker, opts),
             do: LandingWatch.rework(observation, [failure], Keyword.delete(opts, :hold_rework))

      {:error, _} = error ->
        error
    end
  end

  defp defer_if_refused(observation, runs, reason, opts) do
    case preflight_refusal(observation, opts) do
      nil ->
        :ok

      :rerun_backoff ->
        :deferred

      :rerun_limit_reached ->
        with :ok <- Journal.clear_rerun_pending(observation.number, observation.head, opts),
             :ok <- alert_limit(observation, opts),
             do: :deferred

      :merge_group_requeue_limit_reached ->
        mark_refresh_pending(observation, runs, reason, opts)

      refusal when is_atom(refusal) ->
        {:error, refusal}

      {:error, _} = error ->
        error
    end
  end

  defp mark_refresh_pending(observation, runs, reason, opts) do
    row = %{"action" => "refresh", "reason" => reason, "checks" => failed_checks(runs), "since_ms" => now(opts)}

    case Journal.mark_rerun_pending(observation.number, observation.head, row, opts) do
      :ok -> :deferred
      error -> error
    end
  end

  defp preflight_refusal(observation, opts) do
    with {:ok, state} <- Journal.state(opts) do
      entry = Map.get(state, "#{observation.number}:#{observation.head}", %{})

      case Journal.rerun_refusal(entry, now(opts)) do
        nil -> MergeGroupJournal.requeue_refusal(state, now(opts))
        refusal -> refusal
      end
    end
  end

  defp base_overlap(observation, opts) do
    with {:ok, base} <- MergeGroupRunFetcher.base_branch(opts),
         {:ok, base_paths} <- Keyword.get(opts, :base_changes_fun, &base_changes/3).(observation.head, base, opts),
         {:ok, own} when is_list(own) <- Keyword.get(opts, :changed_paths_fun, &Client.fetch_pull_request_changed_paths/2).(observation.number, opts) do
      {:ok, Enum.filter(own, &(base_paths == :all or &1 in base_paths))}
    else
      {:error, _} = error -> error
      _ -> {:error, :refresh_overlap_unavailable}
    end
  end

  # Files the base changed since the PR's merge base.
  defp base_changes(head, base, opts) do
    case CIRecovery.read("/compare/#{head}...#{base}", opts) do
      # GitHub lists at most 300 files, so a full list may hide an overlap.
      {:ok, %{"files" => files}} when is_list(files) and length(files) >= 300 -> {:ok, :all}
      {:ok, %{"files" => files}} when is_list(files) -> {:ok, Enum.flat_map(files, &[&1["filename"], &1["previous_filename"]])}
      {:error, _} = error -> error
      _ -> {:error, :base_compare_unavailable}
    end
  end

  defp request_remedy(observation, runs, action, reason, opts) do
    failed = Enum.filter(runs, &(Map.get(&1, "conclusion") in @rerun_conclusions))
    now = now(opts)

    if failed == [] do
      Journal.clear_rerun_pending(observation.number, observation.head, opts)
    else
      reserve_remedy(observation, failed, action, reason, now, opts)
    end
  end

  defp reserve_remedy(observation, failed, :rerun, reason, now, opts) do
    reservation =
      if Keyword.get(opts, :rerun_per_head_reserved, false) do
        Journal.reserve_automatic_rerun_slots(now, length(failed), opts)
      else
        Journal.reserve_automatic_reruns(observation.number, observation.head, now, length(failed), opts)
      end

    case reservation do
      {:ok, count} ->
        {selected, remaining} = Enum.split(failed, count)

        with :ok <- rerun_all(selected, opts),
             :ok <- comment(observation, :rerun, selected, reason, opts),
             do: persist_remaining(observation, remaining, reason, now, opts, true)

      {:error, :merge_group_requeue_limit_reached} ->
        mark_rerun_pending(observation, failed, reason, now, opts, :rerun, Keyword.get(opts, :rerun_per_head_reserved, false))

      {:error, :rerun_backoff} ->
        :ok

      {:error, :rerun_limit_reached} ->
        with :ok <- Journal.clear_rerun_pending(observation.number, observation.head, opts), do: alert_limit(observation, opts)

      {:error, _} = error ->
        error
    end
  end

  defp reserve_remedy(observation, failed, action, reason, now, opts) do
    case Journal.reserve_automatic_rerun(observation.number, observation.head, now, opts) do
      :ok ->
        with :ok <- apply_remedy(action, observation, failed, opts),
             :ok <- comment(observation, action, failed, reason, opts),
             do: Journal.clear_rerun_pending(observation.number, observation.head, opts)

      {:error, :merge_group_requeue_limit_reached} ->
        mark_rerun_pending(observation, failed, reason, now, opts, action, false)

      {:error, :rerun_backoff} ->
        :ok

      {:error, :rerun_limit_reached} ->
        with :ok <- Journal.clear_rerun_pending(observation.number, observation.head, opts), do: alert_limit(observation, opts)

      {:error, _} = error ->
        error
    end
  end

  defp mark_rerun_pending(observation, failed, reason, now, opts, action, per_head_reserved) do
    row = %{
      "action" => to_string(action),
      "reason" => reason,
      "checks" => failed_checks(failed),
      "run_ids" => Enum.map(failed, &Map.get(&1, "run_id")),
      "per_head_reserved" => per_head_reserved,
      "since_ms" => now
    }

    Journal.mark_rerun_pending(observation.number, observation.head, row, opts)
  end

  defp persist_remaining(observation, [], _reason, _now, opts, _per_head_reserved),
    do: Journal.clear_rerun_pending(observation.number, observation.head, opts)

  defp persist_remaining(observation, remaining, reason, now, opts, per_head_reserved),
    do: mark_rerun_pending(observation, remaining, reason, now, opts, :rerun, per_head_reserved)

  defp failed_checks(runs), do: for(run <- runs, run["conclusion"] in @rerun_conclusions, uniq: true, do: run["name"])

  defp apply_remedy(:refresh, observation, _failed, opts) do
    case Keyword.get(opts, :update_branch_fun, &CIRecovery.update_branch/3).(observation.number, observation.head, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :update_branch_unconfirmed}
    end
  end

  defp rerun_all(runs, opts) do
    Enum.reduce_while(runs, :ok, fn run, :ok ->
      case rerun_one(run, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rerun_one(run, opts) do
    id = Map.get(run, "run_id")

    with true <- is_integer(id) and id > 0,
         {:ok, _} <- Keyword.get(opts, :rerun_fun, &CIRecovery.rerun/2).(id, opts) do
      :ok
    else
      false -> {:error, :missing_actions_run_id}
      {:error, _} = error -> error
    end
  end

  defp comment(observation, action, failed, reason, opts) do
    checks = failed |> Enum.map(& &1["name"]) |> Enum.uniq() |> Enum.join(", ")

    body =
      case action do
        :rerun -> "Landing watcher reran the failed CI (#{checks}) on approved head `#{observation.head}`: #{reason}."
        :refresh -> "Landing watcher updated the branch from the base after failed CI (#{checks}) on approved head `#{observation.head}`: #{reason}."
      end

    case Keyword.get(opts, :comment_fun, &Client.create_comment(to_string(&1), &2, &3)).(observation.number, body, opts) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :rerun_comment_unconfirmed}
    end
  end

  defp alert_limit(observation, opts) do
    issue = TicketBranch.ticket_id(get_in(observation.rest || %{}, ["head", "ref"]))
    message = "Approved PR ##{observation.number} exhausted its infra rerun budget for head #{observation.head}; manual CI recovery is needed."
    topic = if is_binary(issue), do: "ticket.#{issue}.pr.ci_recovery.rerun_limit", else: "system.pr.ci_recovery.rerun_limit"
    LandingWatch.emit_once(observation, "rerun-budget-exhausted", topic, message, "rerun_limit_reached", true, opts)
  end

  @doc "Records a merged PR that changed `.github/` or `scripts/`, from a `pr.merged` event."
  @spec record_merge(map(), keyword()) :: :ok | {:error, term()}
  def record_merge(event, opts) do
    with number when is_integer(number) <- merged_number(event),
         true <- merged_into_base?(event, opts),
         {:ok, paths} when is_list(paths) <- Keyword.get(opts, :changed_paths_fun, &Client.fetch_pull_request_changed_paths/2).(number, opts) do
      case Enum.filter(paths, &(String.starts_with?(&1, ".github/") or String.starts_with?(&1, "scripts/"))) do
        [] -> :ok
        ci -> Journal.record_ci_merge(%{"pr" => number, "paths" => ci, "merged_at_ms" => merged_at_ms(event, opts)}, opts)
      end
    else
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  # Firehose events carry the PR's base; a merge into a stacked branch changes no base CI.
  defp merged_into_base?(%{pr: %{"base" => %{"ref" => ref}}}, opts) when is_binary(ref), do: MergeGroupRunFetcher.base_branch(opts) == {:ok, ref}
  defp merged_into_base?(_event, _opts), do: true

  defp merged_number(%{pr: %{"number" => number}}), do: number
  defp merged_number(%{pr: number}) when is_integer(number), do: number
  defp merged_number(_event), do: nil

  defp merged_at_ms(event, opts) do
    value =
      case event do
        %{pr: %{"merged_at" => merged_at}} -> merged_at
        _ -> Map.get(event, :merged_at)
      end

    with true <- is_binary(value), {:ok, datetime, _} <- DateTime.from_iso8601(value) do
      DateTime.to_unix(datetime, :millisecond)
    else
      _ -> Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    end
  end
end
