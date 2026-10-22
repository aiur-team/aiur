defmodule Aiur.LandingWatch.MergeGroupRunFetcher do
  @moduledoc "Fetches the active and completed merge-group workflow runs."
  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{Errors, ResourceFetch, ResourceStore, Transport}
  @page_limit 5

  @spec active_runs(String.t(), String.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def active_runs(owner, repo, base, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    ["queued", "in_progress", "waiting", "requested"]
    |> Enum.reduce_while({:ok, []}, fn status, {:ok, acc} ->
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <>
          URI.encode_query(%{event: "merge_group", per_page: 100, status: status})

      context = %{request: request, token: token, owner: owner, repo: repo, base: base, status: status}

      case read_pages(context, url, [], 0) do
        {:ok, runs} -> {:cont, {:ok, acc ++ runs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, runs} ->
        {:ok, runs |> Enum.filter(&(&1["event"] == "merge_group")) |> Enum.uniq_by(& &1["id"])}

      {:error, _} = error ->
        error
    end
  end

  @spec completed_runs(String.t(), String.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def completed_runs(owner, repo, base, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    url =
      "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <>
        URI.encode_query(%{event: "merge_group", per_page: 100, status: "completed"})

    context = %{request: request, token: token, owner: owner, repo: repo, base: base, status: "completed"}

    with {:ok, runs} <- read_pages(context, url, [], 0),
         do: {:ok, Enum.filter(runs, &(&1["event"] == "merge_group"))}
  end

  # GitHub lists runs newest first, so the first pages hold every run a live queue
  # entry or a recent failure can own. The completed history grows without bound;
  # past the cap, keep what was read instead of failing the whole poll (#4556).
  defp read_pages(_context, _url, acc, @page_limit), do: {:ok, acc}

  # Each page keeps its ETag so an unchanged page costs a free 304 (#4496).
  defp read_pages(context, url, acc, page) do
    key = ResourceStore.key(:landing_merge_group_runs, context.owner, context.repo, "#{context.base}:#{context.status}:#{page}")
    fetcher = fn fetch_opts -> fetch_run_page(context.request, context.token, url, fetch_opts) end

    with {:ok, %{"workflow_runs" => runs, "next" => next}, meta} <-
           ResourceFetch.need(key, fetcher, freshness: ResourceFetch.decision(), reason: "landing merge-group runs") do
      persist_age_index(key, runs, meta)

      case next do
        nil -> {:ok, acc ++ runs}
        next_url -> read_pages(context, next_url, acc ++ runs, page + 1)
      end
    end
  end

  defp persist_age_index(page_key, runs, meta) do
    case ResourceStore.fetch(page_key) do
      {:ok, %{fetched_at_ms: fetched_at_ms}} when fetched_at_ms == meta.fetched_at_ms -> :ok
      _ -> persist_uncached_page_age_index(page_key, runs)
    end
  end

  defp persist_uncached_page_age_index({:landing_merge_group_runs, owner, repo, page_id}, runs) do
    age_key = ResourceStore.key(:landing_merge_group_runs, owner, repo, "#{page_id}:age-index")

    ids =
      runs
      |> Enum.flat_map(fn run ->
        case Map.get(run, "id") do
          id when is_integer(id) -> [%{"id" => id}]
          id when is_binary(id) -> [%{"id" => id}]
          _ -> []
        end
      end)

    case ResourceStore.fetch(age_key) do
      {:ok, %{data: ^ids, etag: etag}} -> ResourceStore.revalidate(age_key, ids, etag)
      _ -> ResourceStore.put_resource(age_key, ids, source: :fetch)
    end
  end

  defp fetch_run_page(request, token, url, fetch_opts) do
    call = %{method: :get, url: url, token: token, caller: "landing_watch_merge_group_runs"}
    call = if is_binary(fetch_opts[:etag]), do: Map.put(call, :etag, fetch_opts[:etag]), else: call

    case request.(call) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}} = response} when is_list(runs) ->
        headers = Map.get(response, :headers, [])
        {:ok, %{"workflow_runs" => runs, "next" => Transport.parse_next_page_url(headers)}, Transport.header(headers, "etag")}

      {:ok, %{status: 200}} ->
        {:error, :invalid_merge_group_run_list}

      {:ok, %{status: 304} = response} ->
        {:not_modified, Transport.header(Map.get(response, :headers, []), "etag") || fetch_opts[:etag]}

      {:ok, %{status: _} = response} ->
        {:error, Errors.github_status_error(response)}

      {:error, reason} ->
        {:error, Errors.classify_error({:error, reason})}
    end
  end

  @spec base_branch(keyword()) :: {:ok, String.t()} | {:error, term()}
  def base_branch(opts) do
    case Keyword.fetch(opts, :base_branch) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _} -> {:error, :invalid_landing_base_branch}
      :error -> {:ok, TrackerSettings.base_branch()}
    end
  rescue
    error -> {:error, {:landing_base_branch_unavailable, Exception.message(error)}}
  end
end
