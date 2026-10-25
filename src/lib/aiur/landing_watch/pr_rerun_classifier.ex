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
    stale_event = stale_merge_event(jobs, started, opts)

    cond do
      Classifier.infrastructure_run?(run) ->
        {:ok, {:rerun, "infrastructure failure"}}

      is_binary(stale_event) ->
        {:ok, {:refresh, "merge ref predates a fix on the base branch; base input fix event base-history:#{stale_event}"}}

      not is_integer(run["run_id"]) ->
        explain_base_fix(run, jobs, started, opts)

      true ->
        case explain_base_fix(run, jobs, started, opts) do
          {:ok, {:refresh, _}} = refresh -> refresh
          {:ok, nil} -> explain_from_workflow(run, jobs, started, observation, opts)
        end
    end
  end

  defp explain_base_fix(run, jobs, started, opts) do
    case base_input_fix?(jobs, started, opts) do
      event when is_binary(event) ->
        {:ok, {:refresh, "base input fix event #{event}"}}

      _ ->
        case concurrent_approved_failure_event(run, jobs, started, opts) do
          event when is_binary(event) -> {:ok, {:refresh, "same check failed on approved PRs with disjoint changes; base input fix event #{event}"}}
          _ -> {:ok, nil}
        end
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

  # A red-to-green base transition is the evidence that the base fixed the check.
  @doc false
  @spec stale_merge_ref?(map(), keyword()) :: boolean()
  def stale_merge_ref?(run, opts) do
    stale_merge_ref?(failing_jobs(run), timestamp_ms(run["started_at"]), opts)
  end

  defp stale_merge_ref?(_jobs, nil, _opts), do: false

  defp stale_merge_ref?(jobs, started, opts) do
    is_binary(stale_merge_event(jobs, started, opts))
  end

  defp stale_merge_event(_jobs, nil, _opts), do: nil

  defp stale_merge_event(jobs, started, opts) do
    history = Keyword.get(opts, :main_history_fun, &main_history/0).() |> Enum.filter(&is_integer(&1.completed_at)) |> Enum.sort_by(& &1.completed_at)
    before = Enum.filter(history, &(&1.completed_at <= started)) |> List.last()
    latest = Enum.filter(history, &(&1.completed_at > started)) |> List.last()

    if is_map(before) and is_map(latest) and
         Enum.all?(jobs, &(conclusion(before, &1["name"]) in @failed)) and
         Enum.all?(jobs, &(conclusion(latest, &1["name"]) in @passing)) do
      Integer.to_string(latest.completed_at)
    end
  end

  defp base_input_fix?(_jobs, nil, _opts), do: nil

  defp base_input_fix?(jobs, started, opts) do
    merges = Keyword.get(opts, :ci_merges_fun, &Journal.ci_merges/1).(opts)

    with {:ok, merges} when is_list(merges) <- merges,
         history <- Keyword.get(opts, :main_history_fun, &main_history/0).(),
         latest when is_map(latest) <-
           history
           |> Enum.filter(&(is_integer(&1.completed_at) and &1.completed_at > started))
           |> Enum.sort_by(& &1.completed_at)
           |> List.last() do
      Enum.find_value(merges, fn merge ->
        (is_integer(merge["merged_at_ms"]) and merge["merged_at_ms"] > started and
           latest.completed_at > merge["merged_at_ms"] and
           dependency_check?(jobs) and relevant_base_inputs?(Map.get(merge, "paths", [])) and
           Enum.all?(jobs, &(conclusion(latest, &1["name"]) in @passing))) &&
          "#{merge["pr"]}:#{merge["merged_at_ms"]}"
      end)
    else
      _ -> nil
    end
  end

  defp relevant_base_inputs?(paths) when is_list(paths) do
    Enum.any?(paths, fn path ->
      Path.basename(path) in ["mix.lock", "mix.exs"]
    end)
  end

  defp relevant_base_inputs?(_), do: false

  defp dependency_check?(jobs),
    do: Enum.any?(jobs, &String.contains?(String.downcase(&1["name"] || ""), ["audit", "dependency", "workflow security", "workflow-security"]))

  defp concurrent_approved_failure_event(_run, jobs, started, opts) do
    passing_jobs = Enum.filter(jobs, &main_check_passed_after?(&1["name"], started, opts))

    if passing_jobs == [] do
      nil
    else
      case disjoint_failure_prs(opts) do
        prs when is_list(prs) ->
          Enum.find_value(passing_jobs, &disjoint_failure_event(&1, prs, Keyword.get(opts, :current_pr)))

        _ ->
          nil
      end
    end
  end

  defp disjoint_failure_prs(opts) do
    case Keyword.get(opts, :disjoint_failure_prs_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Keyword.get_lazy(opts, :disjoint_failure_prs, fn -> disjoint_failure_prs(Keyword.get(opts, :all_observations, []), opts) end)
    end
  end

  defp main_check_passed_after?(name, started, opts) when is_integer(started) do
    Keyword.get(opts, :main_history_fun, &main_history/0).()
    |> Enum.any?(&(is_integer(&1.completed_at) and &1.completed_at > started and conclusion(&1, name) in @passing))
  end

  defp main_check_passed_after?(_name, _started, _opts), do: false

  defp disjoint_failure_event(job, prs, current_pr) do
    current = Enum.find(prs, &(&1.pr == current_pr and job["name"] in &1.checks))

    if is_map(current) do
      peer = Enum.find(prs, &disjoint_peer?(&1, current, job["name"], current_pr))

      if is_map(peer) do
        prs = Enum.map([current, peer], & &1.pr) |> Enum.sort() |> Enum.join("-")
        check = :crypto.hash(:sha256, job["name"]) |> Base.encode16(case: :lower)
        "approved-prs-#{check}-#{prs}"
      end
    end
  end

  defp disjoint_peer?(other, current, check, current_pr) do
    other.pr != current_pr and check in other.checks and MapSet.disjoint?(MapSet.new(current.paths), MapSet.new(other.paths))
  end

  @doc false
  @spec disjoint_failure_prs([map()], keyword()) :: [map()]
  def disjoint_failure_prs(observations, opts) when is_list(observations) do
    fetch = Keyword.get(opts, :failed_checks_fun, &failed_check_names/2)
    paths = Keyword.get(opts, :changed_paths_fun, &Client.fetch_pull_request_changed_paths/2)

    Enum.flat_map(observations, &observation_failure_paths(&1, fetch, paths, opts))
  end

  def disjoint_failure_prs(_, _), do: []

  defp observation_failure_paths(observation, fetch, paths, opts) do
    if Classifier.approved_at_head?(Map.get(observation, :raw, %{})),
      do: fetch_failure_paths(observation, fetch, paths, opts),
      else: []
  end

  defp fetch_failure_paths(observation, fetch, paths, opts) do
    with {:ok, checks} when is_list(checks) <- fetch.(observation, opts),
         {:ok, changed} when is_list(changed) <- paths.(observation.number, opts) do
      [%{pr: observation.number, checks: checks, paths: changed}]
    else
      _ -> []
    end
  end

  defp failed_check_names(%{head: head}, opts) when is_binary(head) do
    case Keyword.get(opts, :ci_status_fun, &Client.fetch_commit_ci_status/2).(head, opts) do
      {:ok, %{check_runs: runs}} ->
        {:ok, for(%{"name" => name, "status" => "completed", "conclusion" => conclusion} <- runs, conclusion in @failed, do: name)}

      _ ->
        {:ok, []}
    end
  end

  defp failed_check_names(_, _), do: {:ok, []}

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
        {:ok, {:infra, %{job: _job, log: _log, blame_complete: _complete}}} ->
          {:cont, {:ok, ["infrastructure failure" | reasons]}}

        {:ok, {:known_non_pr, %{job: _job, log: _log, blame_complete: _complete}}} ->
          {:cont, {:ok, ["known flake" | reasons]}}

        {:ok, _} ->
          {:halt, {:ok, nil}}

        {:error, _} = error ->
          {:halt, error}
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
