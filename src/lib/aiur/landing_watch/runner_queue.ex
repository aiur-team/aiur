defmodule Aiur.LandingWatch.RunnerQueue do
  @moduledoc "Reports queued pull request CI and its age."

  alias Aiur.Alerts
  alias Aiur.GitHub.{Errors, Transport}
  alias Aiur.LandingWatch.Classifier

  @spec report([map()], keyword()) :: :ok | {:error, term()}
  def report(observations, opts \\ []) when is_list(observations) do
    with {:ok, runs} <- queued_runs(opts) do
      queue = summarize(runs, observations, Keyword.get(opts, :now_ms, System.system_time(:millisecond)))
      emit(queue, opts)
    end
  end

  @doc false
  @spec summarize([map()], [map()], integer()) :: map()
  def summarize(runs, observations, now_ms) when is_list(runs) and is_list(observations) and is_integer(now_ms) do
    queued = Enum.filter(runs, &queued_ci_pull_request?/1)
    prs = Map.new(observations, &{&1.number, &1})
    approved = Enum.filter(queued, &approved_run?(&1, prs))
    unapproved = Enum.filter(queued, &unapproved_run?(&1, prs))

    %{
      queued: length(queued),
      approved_queued: length(approved),
      unapproved_queued: length(unapproved),
      unattributed_queued: length(queued) - length(approved) - length(unapproved),
      deferred: 0,
      oldest_age_ms: oldest_age(queued, now_ms),
      oldest_approved_age_ms: oldest_age(approved, now_ms)
    }
  end

  def summarize(_, _, _), do: %{queued: 0, approved_queued: 0, unapproved_queued: 0, unattributed_queued: 0, deferred: 0, oldest_age_ms: nil, oldest_approved_age_ms: nil}

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

  defp emit(queue, opts) do
    emitter = Keyword.get(opts, :alert_emitter, &Alerts.emit_system/2)

    case emitter.("system.ci.runner_queue",
           message: "CI runner queue: #{queue.queued} queued pull_request runs, #{queue.approved_queued} approved at the observed head; oldest queued age #{queue.oldest_age_ms || 0} ms",
           reason: "queued_ci_runs",
           severity: "info",
           exchange_payload: Map.new(queue, fn {key, value} -> {Atom.to_string(key), value} end)
         ) do
      :ok -> :ok
      {:ok, _, _} -> :ok
      :deduped -> :ok
      :filtered -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp queued_ci_pull_request?(%{"name" => "ci", "status" => "queued", "event" => "pull_request"}), do: true
  defp queued_ci_pull_request?(_), do: false

  defp approved_run?(%{"head_sha" => head} = run, observations) do
    observation = Map.get(observations, pull_number(run))
    is_binary(head) and observation_head(observation) == head and observation_approved?(observation)
  end

  defp approved_run?(_, _), do: false

  defp unapproved_run?(%{"head_sha" => head} = run, observations) do
    observation = Map.get(observations, pull_number(run))
    is_binary(head) and observation_head(observation) == head and is_map(observation) and not observation_approved?(observation)
  end

  defp unapproved_run?(_, _), do: false

  defp pull_number(%{"pull_requests" => [%{"number" => number} | _]}) when is_integer(number), do: number
  defp pull_number(_), do: nil

  defp observation_head(%{head: head}), do: head
  defp observation_head(_), do: nil

  defp observation_approved?(%{raw: raw}), do: Classifier.approved_at_head?(raw)
  defp observation_approved?(_), do: false

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
end
