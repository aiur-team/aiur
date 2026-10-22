defmodule Aiur.LandingWatch.MergeGroupQuarantine do
  @moduledoc """
  Quarantines a flaky test: one that failed in two merge groups whose PRs did not touch it,
  or in base-branch CI and then passed there (`QuarantineEvidence`), within 24 hours.

  Failures are recorded in the landing journal first; quarantine decisions are then made
  from the journal alone, so a GitHub error on one poll is retried on a later one, with
  bounded backoff (`QuarantineRetry`), without re-reading CI. A qualifying test gets a fix
  ticket (`FlakeRecorder`), an auto-merging quarantine PR (`QuarantinePR`), and the approved
  PRs its failures dropped are requeued. OrchestratorGuard failures only feed one fix ticket.
  """

  alias Aiur.GitHub.{CIRecovery, PullRequests}
  alias Aiur.LandingWatch.{FlakeFilingGate, FlakeRecorder, Journal, MergeGroupRequeue, QuarantineAnnotations, QuarantineEvidence, QuarantinePR, QuarantineRetry}
  alias Aiur.LandingWatch.MergeGroupQuarantine.JobEvidence
  alias Aiur.MainWatch
  alias Aiur.TestQuarantine.Detector

  @window_ms 24 * 60 * 60 * 1_000

  @spec process_completed([map()], [map()], String.t(), keyword()) :: :ok | {:error, term()}
  def process_completed(runs, observations, base, opts) do
    {:ok, cache} = Agent.start_link(fn -> %{} end)

    try do
      history = Keyword.get(opts, :main_history_fun, &main_history/0).()
      group_opts = opts |> Keyword.put(:changed_paths_cache, cache) |> Keyword.put(:red_on_main, QuarantineEvidence.red_on_main(history))
      group = runs |> Enum.filter(&eligible_run?/1) |> first_error(&claim_and_process_run(&1, base, group_opts))
      main = record_main_failures(history, opts)
      quarantine = quarantine_candidates(history, observations, base, opts)
      requeue = retry_requeues(observations, opts)
      Enum.find([group, main, quarantine, requeue], :ok, &(&1 != :ok))
    after
      Agent.stop(cache)
    end
  end

  @doc "Merge-group run ids whose recorded failure is a quarantined test; their PRs are requeued, not reworked."
  @spec quarantined_run_ids(keyword()) :: [pos_integer()]
  def quarantined_run_ids(opts) do
    case Journal.state(opts) do
      {:ok, state} ->
        done = Map.get(state, "flakes", %{})

        state
        |> Map.get("failure_observations", [])
        |> Enum.filter(&(&1["source"] != "base" and &1["touched"] != true and Map.has_key?(done, quarantine_claim(&1["identity"]))))
        |> Enum.map(&run_id(&1["run_url"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # One failure must not hold back the rest; report the first error after trying all.
  defp first_error(items, fun) do
    Enum.reduce(items, :ok, fn item, first ->
      result = fun.(item)
      if first == :ok and match?({:error, _}, result), do: result, else: first
    end)
  end

  defp eligible_run?(%{"conclusion" => "failure", "id" => id} = run) when is_integer(id) do
    case run_time(run) do
      {:ok, at_ms} -> recent?(at_ms, System.system_time(:millisecond))
      _ -> false
    end
  end

  defp eligible_run?(_run), do: false

  defp recent?(at_ms, now), do: is_integer(at_ms) and at_ms <= now and now - at_ms <= @window_ms

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
    with prs when prs != [] <- run_prs(run, base),
         {:ok, at_ms} <- run_time(run),
         {:ok, _jobs, found, evidence_complete?} <- JobEvidence.load(run["id"], opts),
         :ok <- record_guards(found.guards, run, opts) do
      tests = Enum.filter(found.tests, &is_binary(&1.path))

      case Enum.uniq_by(tests, & &1.module) do
        [_] -> first_error(tests, &record_observations(&1, run, prs, at_ms, evidence_complete?, opts))
        [] -> :ok
        _modules -> record_cascade(tests, run, prs, opts)
      end
    else
      [] -> :ok
      {:error, _} = error -> error
    end
  end

  # A shard attempt with failures in multiple modules can contain setup/leaked-state
  # cascades. File one diagnostic ticket for the module with the most failures (ties
  # keep log/annotation order), and do not turn any of that attempt into quarantine evidence.
  defp record_cascade(tests, run, prs, opts) do
    {primary, cascades} = primary_module(tests)

    with {:ok, untouched_by_any_pr?} <- paths_leave_failure_unexplained?(primary, prs, opts) do
      if untouched_by_any_pr? do
        failure = Map.put(primary, :cascade_modules, cascades)
        recorder = Keyword.get(opts, :flake_recorder, &FlakeRecorder.record/4)
        recorder.(failure, run, [], Keyword.delete(opts, :issue_recorded_fun))
      else
        :ok
      end
    end
  end

  defp paths_leave_failure_unexplained?(failure, prs, opts) do
    changed_paths = Keyword.get(opts, :changed_paths_fun, &PullRequests.fetch_pull_request_changed_paths/2)

    Enum.reduce_while(prs, {:ok, false}, fn pr, {:ok, found_untouched?} ->
      case cached_changed_paths(pr, changed_paths, opts) do
        {:ok, paths} when is_list(paths) ->
          untouched? = not QuarantineEvidence.touched?(failure.path, paths)
          {:cont, {:ok, found_untouched? or untouched?}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp primary_module(tests) do
    grouped = Enum.group_by(tests, & &1.module)

    primary_module =
      tests
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Enum.max_by(&length(Map.fetch!(grouped, &1)))

    primary = grouped |> Map.fetch!(primary_module) |> List.first()
    cascades = grouped |> Map.keys() |> Enum.reject(&(&1 == primary_module)) |> Enum.sort()
    {primary, cascades}
  end

  # The guard names the last test to finish, not the cause, so it files evidence on one ticket only.
  defp record_guards(guards, run, opts) do
    recorder = Keyword.get(opts, :flake_recorder, &FlakeRecorder.record/4)
    guards |> Enum.uniq() |> first_error(&recorder.(&1, run, [], Keyword.delete(opts, :issue_recorded_fun)))
  end

  defp record_observations(failure, run, prs, at_ms, evidence_complete?, opts) do
    first_error(prs, &record_pr_observation(&1, failure, run, at_ms, prs, evidence_complete?, opts))
  end

  defp record_pr_observation(pr, failure, run, at_ms, prs, evidence_complete?, opts) do
    changed_paths = Keyword.get(opts, :changed_paths_fun, &PullRequests.fetch_pull_request_changed_paths/2)

    case cached_changed_paths(pr, changed_paths, opts) do
      {:ok, paths} when is_list(paths) ->
        row = group_row(pr, failure, run, at_ms, prs, opts, QuarantineEvidence.touched?(failure.path, paths), evidence_complete?)
        record_metric_and_quarantine(row, opts)

      {:error, _} = error ->
        error
    end
  end

  defp record_metric_and_quarantine(row, opts) do
    with :ok <- Journal.record_failure_metric_evidence(row, opts) do
      quarantine_record(row, opts)
    end
  end

  defp quarantine_record(%{"touched" => true} = row, opts), do: Journal.forget_failure_observation(row, opts)
  defp quarantine_record(row, opts), do: Journal.record_failure_observation(row, opts)

  defp group_row(pr, failure, run, at_ms, prs, opts, touched?, evidence_complete?) do
    identity = "#{failure.module} :: #{failure.name}"

    %{
      "identity" => identity,
      # A group failure while main fails the same test is the regression showing through, not flake evidence.
      "red_on_main" => identity in Keyword.get(opts, :red_on_main, []),
      "pr" => pr,
      "run_url" => run["html_url"],
      "head_sha" => run["head_sha"],
      "job_failure_set_complete" => evidence_complete?,
      "failure_class" => Map.get(failure, :class),
      "touched" => touched?,
      "at_ms" => at_ms,
      "path" => failure.path,
      "job" => failure.job,
      "excerpt" => failure.excerpt,
      "group_prs" => prs
    }
  end

  defp cached_changed_paths(pr, changed_paths, opts) do
    case Keyword.get(opts, :changed_paths_cache) do
      cache when is_pid(cache) -> Agent.get_and_update(cache, &cached_path_result(&1, pr, changed_paths, Keyword.delete(opts, :changed_paths_cache)))
      _ -> changed_paths.(pr, opts)
    end
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

  # Base-branch failures come from the main watcher's digest. Each new red commit costs one
  # read of its changed files and one annotation read per failed check, once.
  defp record_main_failures(history, opts) do
    now = System.system_time(:millisecond)

    with {:ok, state} <- Journal.state(opts) do
      scanned = Map.get(state, "flakes", %{})
      retry_now = QuarantineRetry.now(opts)

      history
      |> Enum.filter(&(recent?(Map.get(&1, :completed_at), now) and failed_checks?(&1)))
      |> Enum.reject(&Map.has_key?(scanned, main_claim(&1)))
      |> Enum.filter(&QuarantineRetry.due?(state, main_claim(&1), retry_now))
      |> first_error(&record_main_entry(&1, opts))
    end
  end

  defp record_main_entry(entry, opts) do
    claim = main_claim(entry)

    rows = main_rows(entry)

    with {:ok, :new} <- Journal.claim_flake(claim, opts),
         {:ok, paths} <- if(rows == [], do: {:ok, []}, else: commit_paths(entry.sha, opts)),
         :ok <- record_main_guards(entry, opts),
         :ok <- rows |> Enum.map(&Map.put(&1, "touched", QuarantineEvidence.touched?(&1["path"], paths))) |> first_error(&Journal.record_failure_observation(&1, opts)) do
      :ok
    else
      {:ok, :already_claimed} -> :ok
      # Released for a later poll, but only after the shared backoff: a failed read is not repeated every poll.
      {:error, _} = error -> QuarantineRetry.failed(claim, release_flake_claim(claim, error, opts), opts)
    end
  end

  defp failed_checks?(%{digest: %{checks: [_ | _]}, sha: sha}) when is_binary(sha), do: true
  defp failed_checks?(_entry), do: false

  defp main_claim(entry), do: "quarantine-base-scan :: #{entry.sha}"

  defp commit_paths(sha, opts) do
    case Keyword.get(opts, :commit_paths_fun, &fetch_commit_paths/2).(sha, opts) do
      {:ok, paths} when is_list(paths) -> {:ok, paths}
      {:error, _} = error -> error
      _ -> {:error, :invalid_commit_paths}
    end
  end

  defp fetch_commit_paths(sha, opts) do
    case CIRecovery.read("/commits/#{sha}", Keyword.put(opts, :caller, "landing_watch_quarantine_commit")) do
      {:ok, %{"files" => files}} when is_list(files) -> {:ok, Enum.map(files, & &1["filename"])}
      {:ok, _} -> {:error, :invalid_commit_files}
      {:error, _} = error -> error
    end
  end

  defp record_main_guards(%{digest: %{checks: checks}} = entry, opts) do
    with {:ok, found} <- QuarantineAnnotations.from_checks(Enum.map(checks, &{&1[:id], &1[:name]}), opts) do
      record_guards(found.guards, %{"id" => run_id(main_url(entry, nil)), "html_url" => main_url(entry, nil)}, opts)
    end
  end

  defp main_history do
    if Process.whereis(MainWatch), do: Map.get(MainWatch.state(), :history, []), else: []
  end

  defp main_rows(%{digest: %{checks: checks}} = entry) when is_list(checks) do
    for %{tests: tests} = check <- checks, is_list(tests), test <- tests, is_binary(test[:identity]) do
      %{
        "identity" => test.identity,
        "source" => "base",
        "run_url" => main_url(entry, check),
        "head_sha" => entry[:sha],
        "at_ms" => entry.completed_at,
        "path" => test[:path],
        "job" => check[:name],
        "excerpt" => "",
        "group_prs" => []
      }
    end
  end

  defp main_rows(_entry), do: []

  defp main_url(entry, check), do: (check && check[:url]) || Enum.find_value(entry.digest.checks, & &1[:url]) || List.first(Map.get(entry, :run_urls, []))

  defp quarantine_candidates(history, observations, base, opts) do
    with {:ok, state} <- Journal.state(opts) do
      rows = Map.get(state, "failure_observations", [])
      done = Map.get(state, "flakes", %{})
      tickets = Map.get(state, "flake_tickets", %{})
      now = QuarantineRetry.now(opts)

      rows
      |> candidates(history, System.system_time(:millisecond))
      |> Enum.reject(&Map.has_key?(done, quarantine_claim(&1.identity)))
      |> Enum.filter(&QuarantineRetry.due?(state, quarantine_claim(&1.identity), now))
      |> first_error(&quarantine_with_retry(&1, Map.get(tickets, &1.identity), done, rows, observations, base, opts))
    end
  end

  defp candidates(rows, history, now) do
    recent = Enum.filter(rows, &recent?(&1["at_ms"], now))
    recent = Enum.reject(recent, &(&1["red_on_main"] == true or &1["touched"] == true))
    main = recent |> Enum.filter(&(&1["source"] == "base" and &1["touched"] != true and QuarantineEvidence.passed_on_rerun?(history, &1))) |> Enum.map(& &1["identity"])

    repeated =
      case Detector.repeated(Enum.map(recent, &observation/1), now, fn _pr -> {:ok, []} end) do
        {:ok, found} -> Enum.map(found, & &1.identity)
        _ -> []
      end

    red = QuarantineEvidence.red_on_main(history)
    qualifying = Enum.reject(main ++ repeated, &(&1 in red))

    recent
    |> Enum.filter(&(&1["identity"] in qualifying and &1["touched"] != true))
    |> Enum.group_by(& &1["identity"])
    |> Enum.map(fn {identity, matching} ->
      matching = Enum.sort_by(matching, & &1["at_ms"], :desc)
      %{identity: identity, rows: matching, observations: Enum.map(matching, &observation/1)}
    end)
  end

  defp observation(row) do
    %{identity: row["identity"], pr: row["pr"], run_url: row["run_url"], at_ms: row["at_ms"], path: row["path"], group_prs: row["group_prs"]}
  end

  defp quarantine_with_retry(candidate, ticket, done, rows, observations, base, opts) do
    name = quarantine_claim(candidate.identity)

    case quarantine(candidate, ticket, done, rows, observations, base, opts) do
      :ok -> QuarantineRetry.succeeded(name, opts)
      {:error, _} = error -> QuarantineRetry.failed(name, error, opts)
    end
  end

  defp quarantine(candidate, nil, done, rows, _observations, base, opts) do
    [latest | _] = candidate.rows
    skip_claim = "quarantine-skip :: #{candidate.identity} :: #{latest["run_url"]}"

    if Map.has_key?(done, skip_claim) do
      :ok
    else
      case FlakeFilingGate.decide(failure(latest), run(latest), latest["at_ms"], rows, base, opts) do
        :file -> file_ticket_then_quarantine(candidate, latest, opts)
        {:skip, _reason} -> Journal.claim_flake(skip_claim, opts) |> claim_result()
      end
    end
  end

  defp quarantine(candidate, ticket, _done, _rows, _observations, _base, opts), do: open_quarantine(candidate, ticket, opts)

  defp file_ticket_then_quarantine(candidate, latest, opts) do
    remember = fn ticket -> Journal.put_flake_ticket(candidate.identity, ticket, opts) end
    recorder = Keyword.get(opts, :flake_recorder, &FlakeRecorder.record/4)

    with :ok <- recorder.(failure(latest), run(latest), [], Keyword.put(opts, :issue_recorded_fun, remember)),
         {:ok, state} <- Journal.state(opts) do
      case get_in(state, ["flake_tickets", candidate.identity]) do
        ticket when is_integer(ticket) -> open_quarantine(candidate, ticket, opts)
        # A recorder claim left without a ticket is retried, bounded, rather than re-read every poll.
        _ -> {:error, :flake_ticket_unconfirmed}
      end
    end
  end

  defp open_quarantine(candidate, ticket, opts) do
    claim = quarantine_claim(candidate.identity)

    case Journal.claim_flake(claim, opts) do
      {:ok, :already_claimed} ->
        :ok

      {:ok, :new} ->
        case Keyword.get(opts, :quarantine_pr_fun, &QuarantinePR.open/3).(candidate, ticket, opts) do
          {:ok, _} -> Journal.claim_flake(requeue_claim(candidate.identity), opts) |> claim_result()
          {:error, _} = error -> release_flake_claim(claim, error, opts)
        end

      {:error, _} = error ->
        error
    end
  end

  # The claim is the retry trigger: released, a later poll opens the PR again.
  defp release_flake_claim(claim, error, opts) do
    case Journal.release_flake(claim, opts) do
      :ok -> error
      {:error, reason} -> {:error, {:quarantine_claim_release_failed, reason}}
    end
  end

  # Requeues run as their own step after the PR opens, so a failure retries only the requeue.
  defp retry_requeues(observations, opts) do
    with {:ok, state} <- Journal.state(opts) do
      now = QuarantineRetry.now(opts)
      rows = Map.get(state, "failure_observations", [])

      state
      |> Map.get("flakes", %{})
      |> Map.keys()
      |> Enum.filter(&(String.starts_with?(&1, "quarantine-requeue :: ") and QuarantineRetry.due?(state, &1, now)))
      |> first_error(&requeue_pending(&1, rows, observations, opts))
    end
  end

  defp requeue_pending("quarantine-requeue :: " <> identity = key, rows, observations, opts) do
    case requeue_dropped(identity, rows, observations, opts) do
      :ok -> with :ok <- Journal.release_flake(key, opts), do: QuarantineRetry.succeeded(key, opts)
      {:error, _} = error -> QuarantineRetry.failed(key, error, opts)
    end
  end

  defp requeue_dropped(identity, rows, observations, opts) do
    rows
    |> Enum.filter(&(&1["identity"] == identity and is_list(&1["group_prs"]) and &1["group_prs"] != [] and is_integer(run_id(&1["run_url"]))))
    |> Enum.uniq_by(& &1["run_url"])
    |> first_error(fn row ->
      run = %{"id" => run_id(row["run_url"])}
      MergeGroupRequeue.requeue_group_prs(row["group_prs"], observations, run, "a quarantined flaky test (#{identity})", opts)
    end)
  end

  defp failure(row) do
    [module, name] = String.split(row["identity"], " :: ", parts: 2)
    %{module: module, name: name, job: row["job"] || "unknown job", excerpt: row["excerpt"] || "", path: row["path"]}
  end

  defp run(row), do: %{"id" => run_id(row["run_url"]), "html_url" => row["run_url"], "head_sha" => row["head_sha"]}

  defp quarantine_claim(identity), do: "quarantine-pr :: " <> to_string(identity)
  defp requeue_claim(identity), do: "quarantine-requeue :: " <> to_string(identity)

  defp claim_result({:ok, _}), do: :ok
  defp claim_result(error), do: error

  defp run_id(url) when is_binary(url) do
    case Regex.run(~r{/runs/(\d+)}, url, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp run_id(_url), do: nil

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
