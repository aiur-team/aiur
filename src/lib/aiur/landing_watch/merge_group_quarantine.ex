defmodule Aiur.LandingWatch.MergeGroupQuarantine do
  @moduledoc "Records repeated test failures from unrelated merge-group PRs."

  alias Aiur.GitHub.{CIRecovery, FailureEvidence, PullRequests}
  alias Aiur.LandingWatch.{FlakeRecorder, Journal, QuarantinePR}
  alias Aiur.TestQuarantine.Detector

  @window_ms 24 * 60 * 60 * 1_000

  @spec process_completed([map()], String.t(), keyword()) :: :ok | {:error, term()}
  def process_completed(runs, base, opts) do
    {:ok, cache} = Agent.start_link(fn -> %{} end)

    try do
      runs
      |> Enum.filter(&eligible_run?/1)
      |> Enum.reduce_while(:ok, fn run, :ok ->
        case claim_and_process_run(run, base, Keyword.put(opts, :changed_paths_cache, cache)) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    after
      Agent.stop(cache)
    end
  end

  defp eligible_run?(%{"conclusion" => "failure", "id" => id} = run) when is_integer(id) do
    case run_time(run) do
      {:ok, at_ms} ->
        now = System.system_time(:millisecond)
        at_ms <= now and now - at_ms <= @window_ms

      _ ->
        false
    end
  end

  defp eligible_run?(_run), do: false

  defp claim_and_process_run(run, base, opts) do
    case Journal.claim_quarantine_merge_group_run(run["id"], opts) do
      {:ok, :already_claimed} ->
        :ok

      {:ok, :new} ->
        case process_run(run, base, opts) do
          :ok -> :ok
          {:error, _} = error -> release_run_claim(run["id"], opts, error)
        end

      {:error, _} = error ->
        error
    end
  end

  defp release_run_claim(run_id, opts, error) do
    case Journal.release_quarantine_merge_group_run(run_id, opts) do
      :ok -> error
      {:error, reason} -> {:error, {:quarantine_run_claim_release_failed, reason, error}}
    end
  end

  defp process_run(run, base, opts) do
    with prs <- run_prs(run, base),
         true <- prs != [],
         {:ok, jobs} <- Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(run["id"], opts),
         {:ok, failures} <- test_failures(jobs, opts) do
      process_failures(failures, run, prs, opts)
    else
      false -> :ok
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp process_failures(failures, run, prs, opts) do
    Enum.reduce_while(failures, :ok, fn failure, :ok ->
      case maybe_quarantine(failure, run, prs, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_quarantine(%{path: path} = failure, run, prs, opts) when is_binary(path) do
    with {:ok, at_ms} <- run_time(run),
         :ok <- record_observations(failure, run, prs, path, at_ms, opts),
         {:ok, rows} <- Journal.failure_observations(opts),
         {:ok, candidate} <- repeated(rows, failure),
         do: record_flake(candidate, failure, run, opts)
  end

  defp maybe_quarantine(_failure, _run, _prs, _opts), do: :ok

  defp record_observations(failure, run, prs, path, at_ms, opts) do
    Enum.reduce_while(prs, :ok, fn pr, :ok ->
      case record_pr_observation(pr, failure, run, path, at_ms, prs, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp record_pr_observation(pr, failure, run, path, at_ms, prs, opts) do
    changed_paths = Keyword.get(opts, :changed_paths_fun, &PullRequests.fetch_pull_request_changed_paths/2)

    case cached_changed_paths(pr, changed_paths, opts) do
      {:ok, paths} when is_list(paths) -> persist_if_unrelated(path in paths, pr, failure, run, path, at_ms, prs, opts)
      {:error, _} = error -> error
    end
  end

  defp cached_changed_paths(pr, changed_paths, opts) do
    case Keyword.get(opts, :changed_paths_cache) do
      cache when is_pid(cache) ->
        cached_agent_paths(cache, pr, changed_paths, Keyword.delete(opts, :changed_paths_cache))

      _ ->
        changed_paths.(pr, opts)
    end
  end

  defp cached_agent_paths(cache, pr, changed_paths, opts) do
    Agent.get_and_update(cache, fn entries -> cached_path_result(entries, pr, changed_paths, opts) end)
  end

  defp cached_path_result(entries, pr, changed_paths, opts) do
    case Map.fetch(entries, pr) do
      {:ok, result} ->
        {result, entries}

      :error ->
        result = changed_paths.(pr, opts)
        {result, Map.put(entries, pr, result)}
    end
  end

  defp persist_if_unrelated(true, _pr, _failure, _run, _path, _at_ms, _prs, _opts), do: :ok

  defp persist_if_unrelated(false, pr, failure, run, path, at_ms, prs, opts) do
    row = %{
      "identity" => "#{failure.module} :: #{failure.name}",
      "pr" => pr,
      "run_url" => run["html_url"],
      "at_ms" => at_ms,
      "path" => path,
      "group_prs" => prs
    }

    Journal.record_failure_observation(row, opts)
  end

  defp repeated(rows, failure) do
    identity = "#{failure.module} :: #{failure.name}"

    normalized =
      Enum.map(rows, fn row ->
        %{
          identity: row["identity"],
          pr: row["pr"],
          run_url: row["run_url"],
          at_ms: row["at_ms"],
          path: row["path"],
          group_prs: row["group_prs"]
        }
      end)

    # Journal rows are persisted only after record_pr_observation checks the test path.
    # Re-fetching old PR file lists here would repeat GitHub reads on every new run.
    case Detector.repeated(normalized, System.system_time(:millisecond), fn _pr -> {:ok, []} end) do
      {:ok, candidates} -> {:ok, Enum.find(candidates, &(&1.identity == identity))}
      {:error, _} = error -> error
    end
  end

  defp record_flake(nil, _failure, _run, _opts), do: :ok

  defp record_flake(candidate, failure, run, opts) do
    issue_recorded_fun = fn ticket -> open_quarantine(candidate, ticket, opts) end

    Keyword.get(opts, :flake_recorder, &FlakeRecorder.record/4).(
      failure,
      run,
      [],
      Keyword.put(opts, :issue_recorded_fun, issue_recorded_fun)
    )
  end

  defp open_quarantine(candidate, ticket, opts) do
    claim = "quarantine-pr :: " <> candidate.identity

    case Journal.claim_flake(claim, opts) do
      {:ok, :already_claimed} ->
        :ok

      {:ok, :new} ->
        result = Keyword.get(opts, :quarantine_pr_fun, &QuarantinePR.open/3).(candidate, ticket, opts)
        if match?({:error, _}, result), do: Journal.release_flake(claim, opts) |> release_result(result), else: :ok

      {:error, _} = error ->
        error
    end
  end

  defp release_result(:ok, result), do: result
  defp release_result({:error, reason}, _result), do: {:error, {:quarantine_pr_claim_release_failed, reason}}

  defp test_failures(jobs, opts) do
    jobs
    |> Enum.filter(&(&1["conclusion"] == "failure"))
    |> Enum.reduce_while({:ok, []}, fn job, {:ok, acc} ->
      case job_annotations(job, opts) do
        {:ok, annotations} -> {:cont, {:ok, acc ++ annotation_failures(annotations, job["name"] || "unknown job")}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp job_annotations(job, opts) do
    case check_run_id(job) do
      nil ->
        {:ok, []}

      id ->
        case Keyword.get(opts, :annotations_fun, &FailureEvidence.annotations/2).(id, opts) do
          {:ok, annotations} -> {:ok, annotations}
          {:error, reason} -> {:error, {:merge_group_annotations_unavailable, reason}}
        end
    end
  end

  defp annotation_failures(annotations, job) do
    Enum.flat_map(annotations, fn
      %{"title" => "aiur-test-failure", "message" => message} = annotation when is_binary(message) ->
        case String.split(message, " :: ", parts: 3) do
          [class, module, name] when class in ["known-flake", "new-failure"] and module != "" and name != "" ->
            excerpt = annotation["raw_details"] || annotation["description"] || message
            [%{module: module, name: name, job: job, path: annotation["path"], excerpt: String.slice(String.trim(to_string(excerpt)), 0, 500)}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp check_run_id(%{"check_run_id" => id}) when is_integer(id), do: id

  defp check_run_id(%{"check_run_url" => url}) when is_binary(url) do
    case Regex.run(~r{/check-runs/(\d+)\z}, url, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp check_run_id(_), do: nil

  defp run_prs(run, base) do
    prefix = "gh-readonly-queue/#{base}/"
    branch = run["head_branch"] || ""
    if String.starts_with?(branch, prefix), do: pr_numbers(branch), else: []
  end

  defp pr_numbers(branch), do: Regex.scan(~r/pr-(\d+)-/, branch, capture: :all_but_first) |> List.flatten() |> Enum.map(&String.to_integer/1) |> Enum.uniq()

  defp run_time(%{"created_at" => timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, date, _offset} -> {:ok, DateTime.to_unix(date, :millisecond)}
      _ -> {:error, :invalid_merge_group_timestamp}
    end
  end

  defp run_time(_), do: {:error, :missing_merge_group_timestamp}
end
