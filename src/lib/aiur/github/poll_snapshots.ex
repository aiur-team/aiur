defmodule Aiur.GitHub.PollSnapshots do
  @moduledoc """
  Complete, short-lived selection snapshots shared by webhook and poll reads.

  These are deliberately narrower than a caller's GraphQL document. Review
  decisions and merge verdicts remain live reads; only review-thread and CI
  context collections can be served after a webhook has advanced a complete
  polled baseline.
  """

  alias Aiur.GitHub.ResourceStore

  @delivery_fresh_ms 30_000

  @spec review_threads_key(String.t(), term()) :: ResourceStore.key() | nil
  def review_threads_key(repo, pr_number), do: ResourceStore.key_for_repo(:pr_review_threads, repo, pr_number)

  @spec ci_contexts_key(String.t(), term()) :: ResourceStore.key() | nil
  def ci_contexts_key(repo, target), do: ResourceStore.key_for_repo(:ci_contexts, repo, target)

  @spec review_threads(String.t(), term(), keyword()) :: {:ok, [map()]} | :miss
  def review_threads(repo, pr_number, opts \\ []) do
    with {:ok, %{"complete" => true, "threads" => threads}} when is_list(threads) <-
           delivery_snapshot(review_threads_key(repo, pr_number), opts) do
      {:ok, threads}
    else
      _other -> :miss
    end
  end

  @spec ci_contexts(String.t(), term(), keyword()) :: {:ok, map()} | :miss
  def ci_contexts(repo, target, opts \\ []) do
    with {:ok,
          %{
            "complete" => true,
            "head_sha" => head_sha,
            "check_runs" => check_runs,
            "commit_status" => commit_status
          } = snapshot}
         when is_binary(head_sha) and head_sha != "" and is_list(check_runs) and is_map(commit_status) <-
           delivery_snapshot(ci_contexts_key(repo, target), opts) do
      {:ok, Map.drop(snapshot, ["complete"])}
    else
      _other -> :miss
    end
  end

  @spec put_review_threads(String.t(), term(), [map()], keyword()) :: :ok | :unchanged
  def put_review_threads(repo, pr_number, threads, opts \\ []) when is_list(threads) do
    put_polled_snapshot(
      review_threads_key(repo, pr_number),
      %{"complete" => true, "threads" => threads},
      opts
    )
  end

  @spec put_ci_contexts(String.t(), term(), String.t(), [map()], map(), keyword()) :: :ok | :unchanged
  def put_ci_contexts(repo, target, head_sha, check_runs, commit_status, opts \\ [])
      when is_binary(head_sha) and head_sha != "" and is_list(check_runs) and is_map(commit_status) do
    put_polled_snapshot(
      ci_contexts_key(repo, target),
      %{
        "complete" => true,
        "head_sha" => head_sha,
        "check_runs" => check_runs,
        "commit_status" => commit_status
      },
      opts
    )
  end

  @spec merge_review_thread(String.t(), term(), map()) :: :ok | :unchanged
  def merge_review_thread(repo, pr_number, %{"id" => id} = delivered) when is_binary(id) and id != "" do
    ResourceStore.update_resource(
      review_threads_key(repo, pr_number),
      fn
        %{"complete" => true, "threads" => threads} = held when is_list(threads) ->
          existing = Enum.find(threads, &(Map.get(&1, "id") == id))
          merged = if is_map(existing), do: Map.merge(existing, delivered), else: delivered

          if is_map(existing) and newer_than?(existing, delivered, &thread_marker/1),
            do: :unchanged,
            else: Map.put(held, "threads", replace_resource(threads, id, merged))

        _other ->
          :unchanged
      end,
      source: :webhook,
      version: &snapshot_version/1
    )
  end

  def merge_review_thread(_repo, _pr_number, _delivered), do: :unchanged

  @spec merge_check_run(String.t(), term(), String.t(), map()) :: :ok | :unchanged
  def merge_check_run(repo, target, head_sha, %{"id" => id} = delivered)
      when is_binary(head_sha) and head_sha != "" and not is_nil(id) do
    ResourceStore.update_resource(
      ci_contexts_key(repo, target),
      fn
        %{
          "complete" => true,
          "head_sha" => ^head_sha,
          "check_runs" => check_runs,
          "commit_status" => commit_status
        } = held
        when is_list(check_runs) and is_map(commit_status) ->
          existing = Enum.find(check_runs, &(Map.get(&1, "id") == id))

          if is_map(existing) and newer_than?(existing, delivered, &check_run_marker/1),
            do: :unchanged,
            else: Map.put(held, "check_runs", replace_resource(check_runs, id, delivered))

        _other ->
          :unchanged
      end,
      source: :webhook,
      version: &snapshot_version/1
    )
  end

  def merge_check_run(_repo, _target, _head_sha, _delivered), do: :unchanged

  defp delivery_snapshot(key, opts) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    fresh_ms = Keyword.get(opts, :delivery_fresh_ms, @delivery_fresh_ms)

    case ResourceStore.fetch(key) do
      {:ok, %{data: data, source: :webhook, fetched_at_ms: fetched_at_ms}}
      when is_integer(fetched_at_ms) and now_ms - fetched_at_ms <= fresh_ms and now_ms >= fetched_at_ms ->
        {:ok, data}

      _other ->
        :miss
    end
  end

  defp put_polled_snapshot(key, snapshot, opts) do
    started_at_ms = Keyword.get(opts, :started_at_ms, System.system_time(:millisecond))

    ResourceStore.update_resource(
      key,
      fn _held, metadata ->
        case Map.get(metadata, :fetched_at_ms) do
          fetched_at_ms when is_integer(fetched_at_ms) and fetched_at_ms >= started_at_ms -> :unchanged
          _other -> snapshot
        end
      end,
      source: :poll,
      version: &snapshot_version/1
    )
  end

  defp replace_resource(resources, id, delivered) do
    if Enum.any?(resources, &(Map.get(&1, "id") == id)) do
      Enum.map(resources, fn resource -> if Map.get(resource, "id") == id, do: delivered, else: resource end)
    else
      resources ++ [delivered]
    end
  end

  defp newer_than?(existing, delivered, marker_fun) do
    case {marker_fun.(existing), marker_fun.(delivered)} do
      {existing_marker, delivered_marker} when is_binary(existing_marker) and is_binary(delivered_marker) ->
        existing_marker > delivered_marker

      _other ->
        false
    end
  end

  defp thread_marker(thread) do
    Map.get(thread, "updatedAt") || Map.get(thread, "updated_at") || latest_comment_marker(thread)
  end

  defp latest_comment_marker(thread) do
    thread
    |> get_in(["comments", "nodes"])
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, "updatedAt") || Map.get(&1, "updated_at") || Map.get(&1, "createdAt") || Map.get(&1, "created_at")))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp check_run_marker(run), do: Map.get(run, "completed_at") || Map.get(run, "started_at")

  defp snapshot_version(nil), do: nil

  defp snapshot_version(snapshot) do
    snapshot
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
