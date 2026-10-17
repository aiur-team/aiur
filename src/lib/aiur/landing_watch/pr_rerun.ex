defmodule Aiur.LandingWatch.PrRerun do
  @moduledoc """
  Reruns an approved, not-landing PR's failed CI when the failure has a non-PR
  cause, and routes PR-caused failures to rework.

  Each rerun spends the per-head budget and the shared automatic-requeue cap in
  one journal write. A head deferred by the shared cap stays in the journal's
  rerun backlog until a later poll reruns it. A head whose failure needs a fresh
  merge ref is never rerun; it waits in the same backlog for the Executor.
  """

  alias Aiur.GitHub.{CIRecovery, Client}
  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{Journal, MergeGroupRunFetcher, PrRerunClassifier}
  alias Aiur.TicketBranch

  @rerun_conclusions ["cancelled", "failure", "timed_out", "startup_failure"]
  @caller "landing_watch_pr_rerun"

  @spec handle_failure(map(), map(), [map()], keyword()) :: :ok | {:error, term()}
  def handle_failure(observation, result, runs, opts) do
    with {:ok, state} <- Journal.state(opts) do
      marker = rework_marker(runs, state)
      entry = Map.get(state, "#{observation.number}:#{observation.head}", %{})
      pending = Map.get(entry, "rerun_pending", %{})
      github_opts = Keyword.put(opts, :caller, @caller)
      refusal = Journal.rerun_refusal(entry, now(opts))

      # Cached verdicts, a waiting refresh and a spent budget all skip the classifier's GitHub reads.
      cond do
        Map.has_key?(Map.get(entry, "alerts", %{}), marker) -> LandingWatch.rework(observation, result.failures, opts)
        pending["action"] == "refresh" -> :ok
        refusal == :rerun_backoff -> :ok
        refusal == :rerun_limit_reached -> alert_limit(observation, opts)
        is_binary(pending["reason"]) -> request_reruns(observation, runs, pending["reason"], github_opts)
        true -> classify_and_route(observation, result, runs, marker, github_opts, opts)
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

  defp classify_and_route(observation, result, runs, marker, github_opts, opts) do
    case Keyword.get(opts, :rerun_classifier_fun, &PrRerunClassifier.classify/4).(observation, result, runs, github_opts) do
      {:ok, {:rerun, reason}} ->
        request_reruns(observation, runs, reason, github_opts)

      # A rerun reuses the old merge commit; only a fresh merge ref picks up the base fix.
      {:ok, {:refresh, reason}} ->
        row = %{"action" => "refresh", "reason" => reason, "checks" => failed_checks(runs), "since_ms" => now(opts)}
        Journal.mark_rerun_pending(observation.number, observation.head, row, opts)

      {:ok, :rework} ->
        with {:ok, _} <- Journal.claim_alert(observation.number, observation.head, marker, opts),
             do: LandingWatch.rework(observation, result.failures, opts)

      {:error, _} = error ->
        error
    end
  end

  defp request_reruns(observation, runs, reason, opts) do
    failed = Enum.filter(runs, &(Map.get(&1, "conclusion") in @rerun_conclusions))
    now = now(opts)

    case Journal.reserve_automatic_rerun(observation.number, observation.head, now, opts) do
      :ok ->
        with :ok <- rerun_all(failed, opts),
             :ok <- comment(observation, failed, reason, opts),
             do: Journal.clear_rerun_pending(observation.number, observation.head, opts)

      {:error, :merge_group_requeue_limit_reached} ->
        row = %{"reason" => reason, "checks" => failed_checks(runs), "since_ms" => now}
        Journal.mark_rerun_pending(observation.number, observation.head, row, opts)

      {:error, :rerun_backoff} ->
        :ok

      {:error, :rerun_limit_reached} ->
        with :ok <- Journal.clear_rerun_pending(observation.number, observation.head, opts), do: alert_limit(observation, opts)

      {:error, _} = error ->
        error
    end
  end

  defp failed_checks(runs), do: for(run <- runs, run["conclusion"] in @rerun_conclusions, uniq: true, do: run["name"])

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

  defp comment(observation, failed, reason, opts) do
    checks = failed |> Enum.map(& &1["name"]) |> Enum.uniq() |> Enum.join(", ")
    body = "Landing watcher reran the failed CI (#{checks}) on approved head `#{observation.head}`: #{reason}."

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
