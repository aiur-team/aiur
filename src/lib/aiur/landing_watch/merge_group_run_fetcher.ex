defmodule Aiur.LandingWatch.MergeGroupRunFetcher do
  @moduledoc "Fetches the active and completed merge-group workflow runs."
  alias Aiur.Config.TrackerSettings
  alias Aiur.GitHub.{Errors, Transport}
  @page_limit 5

  @spec active_runs(String.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def active_runs(owner, repo, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    ["queued", "in_progress", "waiting", "requested"]
    |> Enum.reduce_while({:ok, []}, fn status, {:ok, acc} ->
      url =
        "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <>
          URI.encode_query(%{event: "merge_group", per_page: 100, status: status})

      case read_pages(request, token, url, [], 0) do
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

  @spec completed_runs(String.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def completed_runs(owner, repo, token, opts) do
    request = Keyword.get(opts, :request_fun, &Transport.default_request_fun/1)

    url =
      "#{Transport.base_url()}/repos/#{owner}/#{repo}/actions/runs?" <>
        URI.encode_query(%{event: "merge_group", per_page: 100, status: "completed"})

    with {:ok, runs} <- read_pages(request, token, url, [], 0),
         do: {:ok, Enum.filter(runs, &(&1["event"] == "merge_group"))}
  end

  # GitHub lists runs newest first, so the first pages hold every run a live queue
  # entry or a recent failure can own. The completed history grows without bound;
  # past the cap, keep what was read instead of failing the whole poll (#4556).
  defp read_pages(_request, _token, _url, acc, @page_limit), do: {:ok, acc}

  defp read_pages(request, token, url, acc, page) do
    case request.(%{
           method: :get,
           url: url,
           token: token,
           caller: "landing_watch_merge_group_runs"
         }) do
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}} = response} when is_list(runs) ->
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
