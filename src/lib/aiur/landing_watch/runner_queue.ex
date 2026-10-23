defmodule Aiur.LandingWatch.RunnerQueue do
  @moduledoc "Defers queued CI for unapproved pull requests while landing work is waiting."

  alias Aiur.Alerts
  alias Aiur.GitHub.{CIRecovery, Errors, Transport}
  alias Aiur.LandingWatch.{Journal, Observer}

  @default_threshold 8
  @default_drain_threshold 3
  @max_actions_per_poll 10

  @spec reconcile(keyword()) :: :ok | {:error, term()}
  def reconcile(opts \\ []) do
    with {:ok, runs} <- queued_runs(opts),
         {:ok, observations} <- Keyword.get(opts, :observe_all_fun, &Observer.observe_all_open/1).(opts),
         {:ok, deferred} <- Journal.deferred_runner_runs(opts) do
      prs = Map.new(observations, &{&1.number, &1})
      queue = summarize(runs, Keyword.get(opts, :now_ms, System.system_time(:millisecond)))
      threshold = Keyword.get(opts, :threshold, @default_threshold)
      drain = Keyword.get(opts, :drain_threshold, @default_drain_threshold)

      cond do
        queue.total >= threshold -> defer_runs(runs, prs, deferred, queue, opts)
        queue.total <= drain -> restore_runs(deferred, prs, queue, opts)
        true -> report(queue, length(deferred), opts)
      end
    end
  end

  @doc false
  @spec summarize([map()], integer()) :: map()
  def summarize(runs, now_ms \\ System.system_time(:millisecond))

  def summarize(runs, now_ms) when is_list(runs) and is_integer(now_ms) do
    queued = Enum.filter(runs, &(&1["name"] == "ci" and &1["status"] == "queued" and &1["event"] == "pull_request"))

    %{
      total: length(queued),
      oldest_age_ms: oldest_age(queued, now_ms),
      queued: queued
    }
  end

  def summarize(_, _), do: %{total: 0, oldest_age_ms: nil, queued: []}

  @doc false
  @spec census(keyword()) :: {:ok, map()} | {:error, term()}
  def census(opts \\ []) do
    with {:ok, runs} <- queued_runs(opts), do: {:ok, summarize(runs, Keyword.get(opts, :now_ms, System.system_time(:millisecond)))}
  end

  defp queued_runs(opts) do
    with {:ok, {owner, repo}} <- parse_repo(opts),
         {:ok, token} <- Transport.require_token(opts) do
      request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)
      url = "#{Keyword.get(opts, :base_url, Transport.base_url())}/repos/#{owner}/#{repo}/actions/runs?" <> URI.encode_query(%{event: "pull_request", status: "queued", per_page: 100})

      fetch_run_pages(request, token, url, [], 0)
    end
  end

  defp fetch_run_pages(_request, _token, _url, _acc, 10), do: {:error, :runner_queue_page_limit}

  defp fetch_run_pages(request, token, url, acc, page) do
    case request.(%{method: :get, url: url, token: token, caller: "landing_watch_runner_queue"}) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}} = response} when is_list(runs) ->
        next = Transport.parse_next_page_url(Map.get(response, :headers, []))
        if is_nil(next), do: {:ok, acc ++ runs}, else: fetch_run_pages(request, token, next, acc ++ runs, page + 1)

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}

      _ ->
        {:error, :invalid_runner_queue_response}
    end
  end

  defp parse_repo(opts) do
    case Keyword.get(opts, :parse_repo_fun) do
      fun when is_function(fun, 0) -> fun.()
      nil -> Transport.parse_repo()
    end
  end

  defp defer_runs(_runs, prs, deferred, queue, opts) do
    deferred_ids = MapSet.new(deferred, & &1["id"])

    candidates =
      queue.queued
      |> Enum.filter(&deferable_run?(&1, prs, deferred_ids))
      |> Enum.sort_by(& &1["created_at"])
      |> Enum.take(@max_actions_per_poll)

    with {:ok, cancelled} <- cancel_candidates(candidates, prs, opts),
         do: report(queue, length(deferred) + cancelled, opts)
  end

  defp cancel_candidates(candidates, prs, opts) do
    Enum.reduce_while(candidates, {:ok, 0}, fn run, {:ok, cancelled} ->
      pr_number = pull_number(run)
      observation = Map.fetch!(prs, pr_number)

      entry = %{
        "id" => run["id"],
        "pr" => pr_number,
        "head" => observation.head,
        "created_at" => run["created_at"],
        "deferred_at_ms" => now_ms(opts),
        "run_attempt" => run["run_attempt"] || 1
      }

      case defer_and_cancel(run, entry, observation.head, opts) do
        :ok -> {:cont, {:ok, cancelled + 1}}
        {:error, {:runner_cancel_outcome_unknown, _} = reason} -> {:halt, {:error, reason}}
        {:error, _reason} -> {:cont, {:ok, cancelled}}
      end
    end)
  end

  defp defer_and_cancel(run, entry, head, opts) do
    with :ok <- Keyword.get(opts, :deferable_fun, &Observer.revalidate_deferable/3).(entry["pr"], head, opts),
         :ok <- Journal.defer_runner_run(entry, opts) do
      cancel_deferred(run, opts)
    end
  end

  defp cancel_deferred(run, opts) do
    case Keyword.get(opts, :cancel_fun, &CIRecovery.cancel/2).(run["id"], opts) do
      :ok -> :ok
      {:error, reason} -> cancel_error(run, reason, opts)
      _ -> cancel_error(run, :unconfirmed, opts)
    end
  end

  defp cancel_error(run, reason, opts) do
    if cancellation_may_have_landed?(reason) do
      {:error, {:runner_cancel_outcome_unknown, run["id"]}}
    else
      _ = Journal.clear_deferred_runner_run(run["id"], opts)
      {:error, reason}
    end
  end

  defp restore_runs(deferred, prs, queue, opts) do
    selected = Enum.take(deferred, @max_actions_per_poll)

    with :ok <- restore_candidates(selected, prs, opts),
         do: report(queue, max(length(deferred) - length(selected), 0), opts)
  end

  defp restore_candidates(rows, prs, opts) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      pr = Map.get(prs, row["pr"])

      result =
        cond do
          not eligible_for_restore?(pr, row) -> Journal.clear_deferred_runner_run(row["id"], opts)
          row["restore_pending_at_ms"] -> restore_pending(row, opts)
          true -> restore_one(row, opts)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :runner_run_restore_unconfirmed}}
      end
    end)
  end

  defp restore_one(row, opts) do
    mark_restore_pending(row, opts)
    |> then(&rerun_deferred(row, &1, opts))
  end

  defp mark_restore_pending(row, opts), do: Journal.mark_runner_restore_pending(row["id"], now_ms(opts), opts)

  defp rerun_deferred(row, :ok, opts) do
    with :ok <- Keyword.get(opts, :deferable_fun, &Observer.revalidate_deferable/3).(row["pr"], row["head"], opts),
         {:ok, _} <- Keyword.get(opts, :rerun_fun, &CIRecovery.rerun_all/2).(row["id"], opts) do
      Journal.clear_deferred_runner_run(row["id"], opts)
    end
  end

  defp rerun_deferred(_row, error, _opts), do: error

  defp restore_pending(row, opts) do
    with {:ok, %{"status" => status, "head_sha" => sha, "run_attempt" => attempt}} <-
           Keyword.get(opts, :run_fun, fn id, request_opts -> CIRecovery.read("/actions/runs/#{id}", request_opts) end).(row["id"], opts),
         true <- status == "queued" and sha == row["head"] do
      if attempt > (row["run_attempt"] || 1), do: Journal.clear_deferred_runner_run(row["id"], opts), else: restore_one(Map.delete(row, "restore_pending_at_ms"), opts)
    else
      {:error, reason} -> {:error, reason}
      false -> Journal.clear_deferred_runner_run(row["id"], opts)
      _ -> {:error, :runner_restore_observation_invalid}
    end
  end

  defp eligible_for_restore?(%{head: head, state: "OPEN", draft?: false, review_decision: decision, auto_merge_request: nil, merge_queue_entry: nil}, %{"head" => head})
       when decision != "APPROVED" and is_binary(head), do: true

  defp eligible_for_restore?(_, _), do: false

  defp deferable_run?(%{"id" => id} = run, prs, deferred_ids) when is_integer(id) do
    number = pull_number(run)
    observation = Map.get(prs, number)

    is_integer(number) and not MapSet.member?(deferred_ids, id) and
      matching_unapproved_head?(run, observation) and deferable_observation?(observation)
  end

  defp deferable_run?(_, _, _), do: false

  defp matching_unapproved_head?(%{"head_sha" => head}, %{head: head, state: "OPEN", draft?: false, review_decision: decision})
       when is_binary(head) and decision != "APPROVED",
       do: true

  defp matching_unapproved_head?(_, _), do: false

  defp deferable_observation?(%{head: head, state: "OPEN", draft?: false, review_decision: decision, auto_merge_request: nil, merge_queue_entry: nil})
       when is_binary(head) and decision != "APPROVED",
       do: true

  defp deferable_observation?(_), do: false

  defp pull_number(%{"pull_requests" => [%{"number" => number}]}) when is_integer(number), do: number
  defp pull_number(_), do: nil

  defp report(queue, deferred, opts) do
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

    case emitter.("system.ci.runner_queue",
           message: "CI runner queue: #{queue.total} queued pull_request runs, #{deferred} deferred; oldest queued age #{queue.oldest_age_ms || 0} ms",
           reason: "queued_ci_runs",
           severity: "info",
           exchange_payload: %{"queued" => queue.total, "deferred" => deferred, "oldest_age_ms" => queue.oldest_age_ms, "threshold" => Keyword.get(opts, :threshold, @default_threshold)}
         ) do
      :ok -> :ok
      {:ok, _, _} -> :ok
      :deduped -> :ok
      :filtered -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp cancellation_may_have_landed?({:aiur, :unknown, _}), do: true
  defp cancellation_may_have_landed?({:transport, _}), do: true
  defp cancellation_may_have_landed?(_), do: false

  defp oldest_age(runs, now_ms) do
    runs
    |> Enum.map(&timestamp_ms(&1["created_at"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      created -> max(now_ms - created, 0)
    end
  end

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} -> DateTime.to_unix(timestamp, :millisecond)
      _ -> nil
    end
  end

  defp timestamp_ms(_), do: nil
  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))
end
