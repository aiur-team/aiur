defmodule Aiur.LandingWatch.PrRefreshSafety do
  @moduledoc false

  alias Aiur.Events.GithubCIPoller
  alias Aiur.GitHub.Client
  alias Aiur.LandingWatch.MergeGroupRunFetcher

  @spec apply(map(), keyword()) :: :ok | {:error, term()}
  def apply(observation, opts) do
    with :ok <- refreshable_head(observation),
         :ok <- verify_live_head(observation, opts),
         :ok <- verify_no_base_overlap(observation, opts) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  @spec verify_updated_head(map(), keyword()) :: :ok | {:error, term()}
  def verify_updated_head(observation, opts) do
    with {:ok, refreshed} <- Keyword.fetch!(opts, :observe_refresh_fun).(observation.number, opts) do
      verify_approval_carry(observation, refreshed, opts)
    end
  end

  defp refreshable_head(%{review_decision: "APPROVED", head: head, reviews: [%{"commit" => %{"oid" => head}} | _]}) when is_binary(head), do: :ok
  defp refreshable_head(%{review_decision: decision, draft?: false}) when decision in [nil, "", "REVIEW_REQUIRED"], do: :ok
  defp refreshable_head(_), do: {:error, :pr_head_not_refreshable}

  defp verify_live_head(%{number: number, head: head}, opts) do
    case Keyword.fetch!(opts, :refresh_observation_fun).(number, opts) do
      {:ok, %{"state" => "OPEN", "headRefOid" => ^head, "isDraft" => false, "reviewDecision" => decision, "mergeQueueEntry" => nil}}
      when decision in [nil, "", "REVIEW_REQUIRED", "APPROVED"] ->
        :ok

      {:ok, %{"state" => "OPEN", "headRefOid" => ^head, "isDraft" => false, "reviewDecision" => "CHANGES_REQUESTED"}} ->
        {:error, :changes_requested}

      {:ok, _} ->
        {:error, :pr_head_not_refreshable}

      {:error, _} = error ->
        {:error, {:pr_observation_unavailable, error}}

      _ ->
        {:error, :pr_observation_unavailable}
    end
  end

  defp verify_no_base_overlap(observation, opts) do
    case Keyword.get(opts, :refresh_overlap) do
      {:ok, []} -> :ok
      {:ok, paths} when is_list(paths) and paths != [] -> {:error, {:base_changed_pr_files, paths}}
      {:ok, []} -> :ok
      {:error, _} = error -> error
      nil -> fetch_and_verify_no_base_overlap(observation, opts)
      _ -> {:error, :refresh_overlap_unavailable}
    end
  end

  defp fetch_and_verify_no_base_overlap(observation, opts) do
    with {:ok, base} <- MergeGroupRunFetcher.base_branch(opts),
         {:ok, base_changes} <- Keyword.fetch!(opts, :base_changes_fun).(observation.head, base, opts),
         {:ok, base_paths} <- normalize_base_paths(base_changes),
         {:ok, own_paths} when is_list(own_paths) <- Keyword.get(opts, :changed_paths_fun, &Client.fetch_pull_request_changed_paths/2).(observation.number, opts) do
      overlap = Enum.filter(own_paths, &(base_paths == :all or &1 in base_paths))
      if overlap == [], do: :ok, else: {:error, {:base_changed_pr_files, overlap}}
    else
      {:error, _} = error -> error
      _ -> {:error, :refresh_overlap_unavailable}
    end
  end

  defp normalize_base_paths(%{"files" => files}) when is_list(files) and length(files) >= 300, do: {:ok, :all}
  defp normalize_base_paths(%{"files" => files}) when is_list(files), do: {:ok, Enum.flat_map(files, &[&1["filename"], &1["previous_filename"]])}
  defp normalize_base_paths(paths) when is_list(paths), do: {:ok, paths}
  defp normalize_base_paths(_), do: {:error, :refresh_overlap_unavailable}

  defp verify_approval_carry(%{review_decision: "APPROVED"} = observation, %{"headRefOid" => head}, opts) when is_binary(head) and head != "" do
    classifier = Keyword.get(opts, :approval_carry_classifier, &GithubCIPoller.classify_contribution/4)

    case classifier.(observation.head, head, observation.number, opts) do
      :identical -> :ok
      {:changed, evidence} -> {:error, {:approval_not_carried, evidence}}
      other -> {:error, {:approval_carry_unconfirmed, other}}
    end
  end

  defp verify_approval_carry(%{review_decision: decision}, %{"headRefOid" => head}, _opts)
       when decision in [nil, "", "REVIEW_REQUIRED"] and is_binary(head) and head != "",
       do: :ok

  defp verify_approval_carry(_observation, _refreshed, _opts), do: {:error, :refreshed_head_unconfirmed}
end
