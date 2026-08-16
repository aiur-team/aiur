defmodule Aiur.BuildOrder.GitHubGraph.TestAdapter do
  @moduledoc false

  alias Aiur.BuildOrder.GitHubGraph.{Pager, Result, Settings}
  alias Aiur.GitHub.Transport
  alias Aiur.TrackerIdentity

  @member_limit 100
  @max_page_budget 4
  @max_call_budget 4

  @spec fetch_catalog(keyword()) :: Aiur.BuildOrder.GitHubGraph.result()
  def fetch_catalog(opts \\ []) do
    with {:ok, repository} <- repository(opts),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, limits} <- limits(opts) do
      state = Settings.initial_state(opts, limits)
      # Mirrors `GitHubGraph.fetch_catalog/1`: per-member labels are opt-in so a
      # test can exercise both the cheap and the labelled catalog read (#1766).
      paging =
        repository
        |> Settings.new_paging(token, limits, limits.root_limit)
        |> Map.put(:member_labels?, Keyword.get(opts, :member_labels, false) == true)

      case Pager.catalog(paging, state) do
        {:ok, nodes, state} -> Result.catalog(nodes, repository, state)
        {:error, reason, state} -> Result.failure(reason, state)
      end
    else
      {:error, reason} -> Result.failure(reason, Settings.initial_state(opts))
    end
  end

  @spec fetch_selected_root(TrackerIdentity.t(), keyword()) :: Aiur.BuildOrder.GitHubGraph.result()
  def fetch_selected_root(root, opts \\ []) do
    with {:ok, repository} <- repository(opts),
         {:ok, requested_root} <- Settings.requested_root(root, repository),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, limits} <- limits(opts) do
      state = Settings.initial_state(opts, limits)
      paging = Settings.new_paging(repository, token, limits, @member_limit, requested_root)

      case Pager.selected(paging, state) do
        {:ok, root_node, member_nodes, state} -> Result.selected(root_node, member_nodes, repository, state)
        {:error, reason, state} -> Result.failure(reason, state)
      end
    else
      {:error, reason} -> Result.failure(reason, Settings.initial_state(opts))
    end
  end

  defp repository(opts) do
    case Keyword.get(opts, :repository) do
      {owner, repository} when is_binary(owner) and is_binary(repository) and owner != "" and repository != "" ->
        {:ok, {owner, repository}}

      _ ->
        {:error, :invalid_github_repo}
    end
  end

  defp limits(opts) do
    limits = %{
      root_limit: Keyword.get(opts, :root_limit, @member_limit),
      page_budget: Keyword.get(opts, :page_budget, @max_page_budget),
      call_budget: Keyword.get(opts, :call_budget, @max_call_budget)
    }

    if valid_limits?(limits),
      do: {:ok, Map.put(limits, :page_size, page_size(limits, @member_limit))},
      else: {:error, :invalid_planning_bounds}
  end

  defp valid_limits?(%{root_limit: roots, page_budget: pages, call_budget: calls}) do
    is_integer(roots) and roots in 1..@member_limit and
      is_integer(pages) and pages in 1..@max_page_budget and
      is_integer(calls) and calls in 1..@max_call_budget
  end

  defp page_size(limits, limit) do
    slots = min(limits.page_budget, limits.call_budget)
    max(1, div(limit + slots - 1, slots))
  end
end
