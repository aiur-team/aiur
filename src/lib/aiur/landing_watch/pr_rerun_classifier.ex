defmodule Aiur.LandingWatch.PrRerunClassifier do
  @moduledoc """
  Decides whether an approved PR's failed required checks have a non-PR cause.

  Every failed required run must be explained, cheapest evidence first: an
  infrastructure failure, a merge ref that predates a fix on the base branch, a
  CI change merged after the run started, a job name the base workflow no longer
  defines, or a known flake in a test the PR does not touch. Anything else is
  the PR's own failure and routes to rework.

  A rerun reuses the run's merge commit and workflow file, so only infrastructure
  failures and known flakes are rerun. A stale merge ref, a newer CI change or a
  superseded job needs a fresh merge ref instead (`:refresh`).
  """

  alias Aiur.GitHub.{CIRecovery, Client}
  alias Aiur.LandingWatch.{Classifier, Journal, MergeFailureClassifier, MergeFailureOptions, MergeGroupFailureEvidence, MergeGroupRunFetcher, WorkflowTimeouts}

  @failed ["failure", "timed_out", "startup_failure"]
  @passing ["success", "neutral", "skipped"]

  @spec classify(map(), map(), [map()], keyword()) :: {:ok, {:rerun | :refresh, String.t()} | :rework} | {:error, term()}
  def classify(observation, result, runs, opts) do
    if Classifier.infra_failure?(result, runs) do
      {:ok, {:rerun, "infrastructure failure"}}
    else
      names = MapSet.new(result.failures, & &1.name)
      failed = Enum.filter(runs, &(&1["status"] == "completed" and &1["conclusion"] in ["cancelled" | @failed] and &1["name"] in names))
      explain_all(failed, observation, opts)
    end
  end

  defp explain_all([], _observation, _opts), do: {:ok, :rework}

  defp explain_all(failed, observation, opts) do
    Enum.reduce_while(failed, {:ok, []}, fn run, {:ok, reasons} ->
      case explain(run, observation, opts) do
        {:ok, nil} -> {:halt, {:ok, :rework}}
        {:ok, explained} -> {:cont, {:ok, [explained | reasons]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reasons} when is_list(reasons) -> {:ok, remedy(Enum.reverse(reasons))}
      other -> other
    end
  end

  # One cause a rerun cannot fix makes the whole head wait for a fresh merge ref.
  defp remedy(reasons) do
    action = if Enum.any?(reasons, &match?({:refresh, _}, &1)), do: :refresh, else: :rerun
    {action, for({^action, reason} <- reasons, uniq: true, do: reason) |> Enum.join("; ")}
  end

  defp explain(run, observation, opts) do
    jobs = failing_jobs(run)
    started = timestamp_ms(run["started_at"])

    cond do
      Classifier.infrastructure_run?(run) -> {:ok, {:rerun, "infrastructure failure"}}
      stale_merge_ref?(jobs, started, opts) -> {:ok, {:refresh, "merge ref predates a fix on the base branch"}}
      not is_integer(run["run_id"]) -> {:ok, nil}
      true -> explain_from_workflow(run, jobs, started, observation, opts)
    end
  end

  defp explain_from_workflow(run, jobs, started, observation, opts) do
    with {:ok, base} <- MergeGroupRunFetcher.base_branch(opts),
         {:ok, path} <- workflow_path(run, opts),
         {:ok, definitions} <- Keyword.get(opts, :workflow_definitions_fun, &WorkflowTimeouts.definitions/3).(path, base, opts),
         {:ok, merges} <- Keyword.get(opts, :ci_merges_fun, &Journal.ci_merges/1).(opts),
         {:ok, changed} <- changed_paths(observation, opts) do
      # A PR that edits its own workflow owns job additions and renames there.
      own_workflow? = path in changed
      opts = Keyword.put(opts, :changed_paths_fun, fn _numbers, _opts -> {:ok, changed} end)

      cond do
        merge = not own_workflow? and ci_change(merges, started, path, jobs, definitions) -> {:ok, {:refresh, "CI change merged in ##{merge["pr"]}"}}
        not own_workflow? and definitions != %{} and Enum.all?(jobs, &(not WorkflowTimeouts.defines_job?(definitions, &1["name"]))) -> {:ok, {:refresh, "superseded job name"}}
        true -> known_flake(run, jobs, base, observation, opts)
      end
    end
  end

  defp changed_paths(observation, opts) do
    case Keyword.get(opts, :changed_paths_fun, &Client.fetch_pull_request_changed_paths/2).(observation.number, opts) do
      {:ok, paths} when is_list(paths) -> {:ok, paths}
      {:error, _} = error -> error
      _ -> {:error, :pull_request_changed_paths_unavailable}
    end
  end

  # The gate job only fails because upstream jobs did; judge the jobs that failed first.
  defp failing_jobs(run) do
    jobs = Enum.filter(Map.get(run, "workflow_jobs", []), &(&1["conclusion"] in @failed))

    case Enum.reject(jobs, &(&1["name"] == run["name"])) do
      [] when jobs != [] -> jobs
      [] -> [%{"name" => run["name"], "conclusion" => run["conclusion"]}]
      upstream -> upstream
    end
  end

  # Base CI was red for every failing job when the run started and is green for each now.
  defp stale_merge_ref?(_jobs, nil, _opts), do: false

  defp stale_merge_ref?(jobs, started, opts) do
    history = Keyword.get(opts, :main_history_fun, &main_history/0).() |> Enum.filter(&is_integer(&1.completed_at)) |> Enum.sort_by(& &1.completed_at)
    before = history |> Enum.filter(&(&1.completed_at <= started)) |> List.last()
    latest = List.last(history)

    is_map(before) and latest.completed_at > started and
      Enum.all?(jobs, &(conclusion(before, &1["name"]) in @failed and conclusion(latest, &1["name"]) in @passing))
  end

  defp conclusion(entry, name), do: Enum.find_value(entry.checks, &(&1.name == name and &1.conclusion))

  defp main_history do
    case Aiur.MainWatch.state() do
      %{history: history} when is_list(history) -> history
      _ -> []
    end
  end

  defp workflow_path(run, opts) do
    case Keyword.get(opts, :actions_run_fun, &CIRecovery.read("/actions/runs/#{&1}", &2)).(run["run_id"], opts) do
      {:ok, %{"path" => path}} when is_binary(path) -> {:ok, path}
      {:error, _} = error -> error
      _ -> {:error, :actions_run_path_unavailable}
    end
  end

  # A merge after the run started matches its workflow file, or a script or action every failing job uses.
  defp ci_change(_merges, nil, _path, _jobs, _definitions), do: nil

  defp ci_change(merges, started, path, jobs, definitions) do
    Enum.find(merges, fn merge ->
      paths = Map.get(merge, "paths", [])
      newer? = is_integer(merge["merged_at_ms"]) and merge["merged_at_ms"] > started
      newer? and (path in paths or Enum.all?(jobs, &uses_any?(definitions, &1["name"], paths)))
    end)
  end

  defp uses_any?(definitions, name, paths) do
    text = definitions |> Enum.filter(fn {id, definition} -> WorkflowTimeouts.defines_job?(%{id => definition}, name) end) |> inspect(limit: :infinity, printable_limit: :infinity)
    Enum.any?(paths, &(String.contains?(text, &1) or (String.starts_with?(&1, ".github/actions/") and String.contains?(text, Path.dirname(&1)))))
  end

  defp known_flake(run, jobs, base, observation, opts) do
    evidence_opts =
      opts
      |> Keyword.put_new_lazy(:recent_main_failure_paths, fn -> MergeGroupFailureEvidence.recent_main_paths(base, opts) end)
      |> Keyword.put_new_lazy(:known_failure_patterns, fn -> MergeGroupFailureEvidence.known_patterns(opts) end)

    run = Map.put(run, "pull_request_numbers", [observation.number])
    classifier_opts = MergeFailureOptions.build(run, [observation.number], jobs, evidence_opts, &MergeGroupFailureEvidence.job_log/2)

    Enum.reduce_while(jobs, {:ok, []}, fn job, {:ok, reasons} ->
      case MergeFailureClassifier.classify(run, [job], [], classifier_opts) do
        {:ok, {:infra, _}} -> {:cont, {:ok, ["infrastructure failure" | reasons]}}
        {:ok, {:known_non_pr, _}} -> {:cont, {:ok, ["known flake" | reasons]}}
        {:ok, _} -> {:halt, {:ok, nil}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, [_ | _] = reasons} -> {:ok, {:rerun, reasons |> Enum.reverse() |> Enum.uniq() |> Enum.join("; ")}}
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_ms(_), do: nil
end
