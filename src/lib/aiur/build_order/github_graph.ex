defmodule Aiur.BuildOrder.GitHubGraph do
  @moduledoc "Bounded, body-free GitHub reads for Build Order planning candidates."

  alias Aiur.BuildOrder.GitHubGraph.{Pager, Result, Settings}
  alias Aiur.GitHub.Transport
  alias Aiur.TrackerIdentity

  @member_limit 100

  @type result :: {:ok, Aiur.BuildOrder.ProviderResult.t()} | {:error, Aiur.BuildOrder.ProviderResult.t()}

  @spec fetch_catalog(keyword()) :: result()
  def fetch_catalog(opts \\ []) do
    with {:ok, repository} <- Settings.configured_repository(opts),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, limits} <- Settings.limits(opts) do
      state = Settings.initial_state(opts)
      paging = Settings.new_paging(repository, token, limits, limits.root_limit)

      case Pager.catalog(paging, state) do
        {:ok, nodes, state} -> Result.catalog(nodes, repository, state)
        {:error, reason, state} -> Result.failure(reason, state)
      end
    else
      {:error, reason} -> Result.failure(reason, Settings.initial_state(opts))
    end
  end

  @spec fetch_selected_root(TrackerIdentity.t(), keyword()) :: result()
  def fetch_selected_root(root, opts \\ []) do
    with {:ok, repository} <- Settings.configured_repository(opts),
         {:ok, requested_root} <- Settings.requested_root(root, repository),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, limits} <- Settings.limits(opts) do
      state = Settings.initial_state(opts)
      paging = Settings.new_paging(repository, token, limits, @member_limit, requested_root)

      case Pager.selected(paging, state) do
        {:ok, root_node, member_nodes, state} -> Result.selected(root_node, member_nodes, repository, state)
        {:error, reason, state} -> Result.failure(reason, state)
      end
    else
      {:error, reason} -> Result.failure(reason, Settings.initial_state(opts))
    end
  end
end
