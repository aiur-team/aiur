defmodule Aiur.LandingWatch.MergeGroups do
  @moduledoc "Cancels active merge-group runs that no longer belong to the live queue."

  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{CIRecovery, Errors, FailureEvidence, Transport}
  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{Attribution, FlakeRecorder, Journal, Observer}
  alias Aiur.PrMerge.Queue

  @page_limit 5

  @spec cancel_stale([map()], keyword()) :: :ok | {:error, term()}
  def cancel_stale(observations, opts \\ [])

  def cancel_stale(observations, opts) when is_list(observations) do
    with {:ok, base} <- base_branch(opts),
         {:ok, {owner, repo}} <- Transport.parse_repo(),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, runs} <- active_runs(owner, repo, token, opts),
         {:ok, completed} <- completed_runs(owner, repo, token, opts),
         {:ok, fresh_observations} <- live_observations(observations, opts) do
      with :ok <- process_completed(completed, fresh_observations, base, opts),
           {:ok, reconciled_observations} <- live_observations(fresh_observations, opts) do
        live = Map.new(Enum.map(reconciled_observations, &live_entry(&1, base)) |> Enum.reject(&is_nil/1))
        cancel_runs(Enum.filter(runs, &stale?(&1, base, live)), opts)
      end
    end
  end

  def cancel_stale(_, _), do: {:error, :invalid_queue_observations}

  defp live_observations(fallback, opts) do
    case Keyword.get(opts, :live_observations_fun, &Observer.refresh_queue/2).(fallback, opts) do
      {:ok, observations} when is_list(observations) -> {:ok, observations}
      {:error, _} = error -> error
      _ -> {:error, :invalid_live_queue_observations}
    end
  end

  defp live_entry(%{base: base, number: number, merge_queue_entry: entry} = observation, base) when is_integer(number) and is_map(entry),
    do:
      {number,
       %{
         head: Map.get(observation, :head),
         committed_at: Map.get(observation, :head_committed_at),
         queue_head: get_in(entry, ["pullRequest", "headRefOid"])
       }}

  defp live_entry(_observation, _base), do: nil

  defp stale?(%{"id" => id, "event" => "merge_group", "status" => status, "head_branch" => branch} = run, base, live)
       when is_integer(id) and status in ["queued", "in_progress", "waiting", "requested"] and is_binary(branch) do
    prefix = "gh-readonly-queue/#{base}/pr-"

    if String.starts_with?(branch, prefix) do
      branch
      |> then(&Regex.scan(~r/pr-(\d+)-/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
      |> Enum.any?(&(not current_entry?(Map.get(live, &1), run)))
    else
      false
    end
  end

  defp stale?(_run, _base, _live), do: false

  defp current_entry?(nil, _run), do: false

  defp current_entry?(%{head: head, committed_at: committed_at, queue_head: queue_head}, %{"created_at" => created_at})
       when is_binary(head) and is_binary(committed_at) and is_binary(queue_head) and is_binary(created_at) do
    queue_head == head and timestamp_at_or_after?(created_at, committed_at)
  end

  defp current_entry?(_entry, _run), do: true

  defp timestamp_at_or_after?(created_at, committed_at) do
    with {:ok, run_time, _} <- DateTime.from_iso8601(created_at),
         {:ok, head_time, _} <- DateTime.from_iso8601(committed_at) do
      DateTime.compare(run_time, head_time) in [:eq, :gt]
    else
      _ -> false
    end
  end

  defp cancel_runs(runs, opts) do
    Enum.reduce(runs, :ok, &cancel_if_ok(&1, &2, opts))
  end

  defp cancel_if_ok(_run, {:error, _} = error, _opts), do: error

  defp cancel_if_ok(run, :ok, opts) do
    case Keyword.get(opts, :cancel_fun, &CIRecovery.cancel/2).(run["id"], opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:merge_group_cancel_failed, run["id"], reason}}
    end
  end

  defp active_runs(owner, repo, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    ["queued", "in_progress", "waiting", "requested"]
    |> Enum.reduce_while({:ok, []}, fn status, {:ok, acc} ->
      url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <> URI.encode_query(%{event: "merge_group", per_page: 100, status: status})

      case read_pages(request, token, url, [], 0) do
        {:ok, runs} -> {:cont, {:ok, acc ++ runs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, runs} -> {:ok, Enum.uniq_by(runs, & &1["id"])}
      {:error, _} = error -> error
    end
  end

  defp completed_runs(owner, repo, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
    url = "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <> URI.encode_query(%{event: "merge_group", per_page: 100, status: "completed"})
    read_pages(request, token, url, [], 0)
  end

  defp process_completed(runs, observations, base, opts) do
    failures = Enum.filter(runs, &(&1["conclusion"] == "failure" and is_integer(&1["id"])))

    Enum.reduce(failures, :ok, fn run, result ->
      if result == :ok, do: process_claimed_failed_group(run, runs, observations, base, opts), else: result
    end)
  end

  defp process_claimed_failed_group(run, runs, observations, base, opts) do
    case Journal.claim_merge_group_run(run["id"], opts) do
      {:ok, :already_claimed} -> :ok
      {:ok, :new} -> process_new_failed_group(run, runs, observations, base, opts)
      {:error, _} = error -> error
    end
  end

  defp process_new_failed_group(run, runs, observations, base, opts) do
    case process_failed_group(run, runs, observations, base, opts) do
      :ok ->
        :ok

      {:error, _} = error ->
        _ = Journal.release_merge_group_run(run["id"], opts)
        error
    end
  end

  defp process_failed_group(run, runs, observations, base, opts) do
    case run_prs(run, base) do
      {:ok, []} -> :ok
      {:ok, prs} -> process_failed_group_for_prs(run, runs, observations, prs, opts)
    end
  end

  defp process_failed_group_for_prs(run, runs, observations, prs, opts) do
    with {:ok, jobs} <- Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(run["id"], opts),
         {:ok, failures} <- test_failures(jobs, opts) do
      Enum.reduce(failures, :ok, &record_if_flaky(&1, &2, run, runs, prs, observations, opts))
    end
  end

  defp record_if_flaky(_failure, {:error, _} = error, _run, _runs, _prs, _observations, _opts), do: error

  defp record_if_flaky(failure, :ok, run, runs, prs, observations, opts) do
    passed = passed_prs(failure, run, runs, prs, opts)
    record_and_requeue(failure, run, passed, observations, opts)
  end

  defp record_and_requeue(_failure, _run, [], _observations, _opts), do: :ok

  defp record_and_requeue(failure, run, passed, observations, opts) do
    case Keyword.get(opts, :flake_recorder, &FlakeRecorder.record/4).(failure, run, passed, opts) do
      :ok -> reenqueue_prs(passed, observations, opts)
      {:error, _} = error -> error
    end
  end

  defp run_prs(run, base) do
    branch = Map.get(run, "head_branch", "")
    prefix = "gh-readonly-queue/#{base}/"
    prs = if is_binary(branch) and String.starts_with?(branch, prefix), do: pr_numbers(branch), else: []
    {:ok, prs}
  end

  defp pr_numbers(branch) when is_binary(branch) do
    Regex.scan(~r/pr-(\d+)-/, branch, capture: :all_but_first) |> List.flatten() |> Enum.map(&String.to_integer/1) |> Enum.uniq()
  end

  defp pr_numbers(_), do: []

  defp test_failures(jobs, opts) do
    jobs
    |> Enum.filter(&(&1["conclusion"] == "failure"))
    |> Enum.reduce_while({:ok, []}, fn job, {:ok, acc} ->
      case check_run_id(job) do
        nil -> {:cont, {:ok, acc}}
        id -> fetch_job_annotations(id, job, acc, opts)
      end
    end)
  end

  defp fetch_job_annotations(id, job, acc, opts) do
    case Keyword.get(opts, :annotations_fun, &FailureEvidence.annotations/2).(id, opts) do
      {:ok, annotations} -> {:cont, {:ok, acc ++ annotation_failures(annotations, job["name"] || "unknown job")}}
      {:error, reason} -> {:halt, {:error, {:merge_group_annotations_unavailable, reason}}}
    end
  end

  defp check_run_id(%{"check_run_id" => id}) when is_integer(id), do: id

  defp check_run_id(%{"check_run_url" => url}) when is_binary(url) do
    case Regex.run(~r{/check-runs/(\d+)\z}, url, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp check_run_id(_), do: nil

  defp annotation_failures(annotations, job) do
    Enum.flat_map(annotations, fn
      %{"title" => "aiur-test-failure", "message" => message} = annotation when is_binary(message) ->
        case String.split(message, " :: ", parts: 3) do
          [class, module, name] when class in ["known-flake", "new-failure"] and module != "" and name != "" ->
            excerpt = annotation["raw_details"] || annotation["description"] || message
            [%{module: module, name: name, job: job, excerpt: String.slice(String.trim(to_string(excerpt)), 0, 500)}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp passed_prs(failure, failed_run, runs, prs, opts) do
    runs
    |> Enum.filter(fn run ->
      run["id"] != failed_run["id"] and run["conclusion"] == "success" and
        Enum.any?(prs, &(&1 in pr_numbers(run["head_branch"]))) and
        successful_job?(run, failure.job, opts)
    end)
    |> Enum.flat_map(&pr_numbers(&1["head_branch"]))
    |> Enum.filter(&(&1 in prs))
    |> Enum.uniq()
  end

  defp successful_job?(run, job_name, opts) do
    case Keyword.get(opts, :jobs_fun, &CIRecovery.jobs/2).(run["id"], opts) do
      {:ok, jobs} -> Enum.any?(jobs, &(&1["name"] == job_name and &1["conclusion"] == "success"))
      _ -> false
    end
  end

  defp reenqueue_prs(numbers, observations, opts) do
    Enum.reduce(numbers, :ok, &reenqueue_if_pending(&1, &2, observations, opts))
  end

  defp reenqueue_if_pending(_number, {:error, _} = error, _observations, _opts), do: error

  defp reenqueue_if_pending(number, :ok, observations, opts) do
    case Enum.find(observations, &(&1.number == number)) do
      %{head: head, node_id: node_id, draft?: false, review_decision: "APPROVED", merge_queue_entry: nil, auto_merge_request: nil} = pr ->
        enqueue_dropped(pr, head, node_id, opts)

      _ ->
        :ok
    end
  end

  defp enqueue_dropped(pr, head, node_id, opts) do
    identity = "flake-requeue"

    with true <- is_binary(head) and is_binary(node_id),
         true <- Keyword.get(opts, :approved_fun, fn _, _ -> {:ok, true} end).(pr.number, opts) == {:ok, true},
         :ok <- Keyword.get(opts, :revalidate_fun, &Observer.revalidate_approved_head/3).(pr.number, head, opts),
         {:ok, :clean} <- Keyword.get(opts, :attribution_fun, fn number -> Attribution.pull_request_clean?(number, opts) end).(pr.number),
         {:ok, :new} <- Journal.claim_alert(pr.number, head, identity, opts),
         {:ok, entry} <- enqueue(pr, node_id, head, opts),
         :ok <- Journal.mark_landed(pr.number, head, entry, opts) do
      :ok
    else
      {:ok, :already_claimed} ->
        :ok

      {:ok, {:ai_attribution, detail}} ->
        LandingWatch.rework(pr, [%{name: "AI commit attribution", excerpt: detail}], opts)

      false ->
        :ok

      {:error, reason} ->
        _ = Journal.release_alert(pr.number, head, identity, opts)
        {:error, reason}

      _ ->
        :ok
    end
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
           do: Transport.github_graphql(Keyword.get(opts, :request_fun, &Transport.default_request_fun/1), token, query, variables, caller: "landing_watch_flake_requeue")
    end

    Queue.enqueue(api, %{node_id: node_id, head: head})
  end

  # GitHub lists runs newest first, so the first pages hold every run a live queue
  # entry or a recent failure can own. The completed history grows without bound;
  # past the cap, keep what was read instead of failing the whole poll (#4556).
  defp read_pages(_request, _token, _url, acc, @page_limit), do: {:ok, acc}

  defp read_pages(request, token, url, acc, page) do
    case request.(%{method: :get, url: url, token: token, caller: "landing_watch_merge_group_runs"}) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}} = response} when is_list(runs) ->
        runs = Enum.filter(runs, &(&1["event"] == "merge_group"))

        case Transport.parse_next_page_url(Map.get(response, :headers, [])) do
          nil -> {:ok, acc ++ runs}
          next -> read_pages(request, token, next, acc ++ runs, page + 1)
        end

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  defp base_branch(opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _} -> {:error, :invalid_landing_base_branch}
      :error -> {:ok, TrackerSettings.base_branch()}
    end
  rescue
    error -> {:error, {:landing_base_branch_unavailable, Exception.message(error)}}
  end
end
