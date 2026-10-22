defmodule Aiur.RunTelemetry.WindowEventSources.CiRuns do
  @moduledoc false

  alias Aiur.GitHub.Transport

  @events ["pull_request", "merge_group"]
  @page_limit 10
  @per_page 100
  @run_limit 10_000

  @spec fetch(function(), String.t(), String.t(), [String.t()], map()) :: {:ok, [map()]} | {:partial, [map()]} | {:error, term()}
  def fetch(request, token, repo, workflows, range) do
    with {:ok, ids, workflow_partial?} <- workflow_ids(request, token, repo, workflows) do
      {rows, partial?} = collect_slices(request, token, repo, ids, days(range), [], workflow_partial?)

      cond do
        rows == [] and partial? -> {:error, :ci_runs_unavailable}
        partial? -> {:partial, rows}
        true -> {:ok, rows}
      end
    end
  end

  defp workflow_ids(request, token, repo, requested) do
    case request.(%{method: :get, url: Transport.base_url() <> "/repos/#{repo}/actions/workflows?per_page=100", token: token, caller: "experiment_window_events"}) do
      {:ok, %{status: 200, body: %{"workflows" => rows, "total_count" => total}}} when is_list(rows) ->
        selected = Enum.flat_map(requested, &matching_ids(&1, rows))
        partial? = total > length(rows)
        if selected == [], do: {:error, :required_workflows_not_found}, else: {:ok, Enum.uniq(selected), partial?}

      _error ->
        {:error, :workflows_unavailable}
    end
  rescue
    _error -> {:error, :workflows_unavailable}
  end

  defp matching_ids(workflow, rows) do
    matches = Enum.filter(rows, &(&1["name"] == workflow or Path.basename(&1["path"] || "") == workflow))
    Enum.map(matches, &to_string(&1["id"]))
  end

  defp days(range) do
    with {:ok, start_at, _} <- DateTime.from_iso8601(range.start),
         {:ok, end_at, _} <- DateTime.from_iso8601(range.end) do
      last_day = end_at |> DateTime.add(-1, :second) |> DateTime.to_date()
      first_day = DateTime.to_date(start_at)
      if Date.compare(last_day, first_day) == :lt, do: [], else: Enum.to_list(Date.range(first_day, last_day))
    else
      _ -> []
    end
  end

  defp collect_slices(_request, _token, _repo, _ids, _days, rows, _partial?) when length(rows) >= @run_limit,
    do: {Enum.take(rows, @run_limit), true}

  defp collect_slices(request, token, repo, ids, days, rows, partial?) do
    slices = for id <- ids, event <- @events, day <- days, do: {id, event, day}

    Enum.reduce_while(slices, {rows, partial?}, &collect_slice(request, token, repo, &1, &2))
  end

  defp collect_slice(_request, _token, _repo, _slice, {rows, _partial?}) when length(rows) >= @run_limit,
    do: {:halt, {Enum.take(rows, @run_limit), true}}

  defp collect_slice(request, token, repo, {id, event, day}, {rows, partial?}) do
    case run_slice(request, token, repo, {id, event, day}, 1, [], 0) do
      {:ok, runs} -> {:cont, {rows ++ runs, partial?}}
      {:partial, runs} -> {:cont, {rows ++ runs, true}}
      {:error, _reason} -> {:cont, {rows, true}}
    end
  end

  defp run_slice(_request, _token, _repo, _slice, _page, rows, _total) when length(rows) >= @per_page * @page_limit,
    do: {:partial, rows}

  defp run_slice(request, token, repo, {id, event, day} = slice, page, rows, total) do
    query = URI.encode_query(%{event: event, created: Date.to_iso8601(day), per_page: @per_page, page: page})
    url = Transport.base_url() <> "/repos/#{repo}/actions/workflows/#{id}/runs?" <> query

    case request.(%{method: :get, url: url, token: token, caller: "experiment_window_events"}) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs, "total_count" => count}}} when is_list(runs) ->
        all = rows ++ runs
        total = max(total, count)

        cond do
          length(all) >= total -> {:ok, all}
          page >= @page_limit or runs == [] -> {:partial, all}
          true -> run_slice(request, token, repo, slice, page + 1, all, total)
        end

      _error when rows == [] ->
        {:error, :ci_runs_unavailable}

      _error ->
        {:partial, rows}
    end
  rescue
    _error -> if(rows == [], do: {:error, :ci_runs_unavailable}, else: {:partial, rows})
  end
end
