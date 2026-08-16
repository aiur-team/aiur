defmodule Aiur.BuildOrder.GitHubGraph do
  @moduledoc "Bounded, body-free GitHub reads for Build Order planning candidates."

  alias Aiur.BuildOrder.GitHubGraph.{Pager, Result, Settings}
  alias Aiur.GitHub.Transport
  alias Aiur.TrackerIdentity

  @member_limit 100

  @type result :: {:ok, Aiur.BuildOrder.ProviderResult.t()} | {:error, Aiur.BuildOrder.ProviderResult.t()}

  @spec fetch_catalog(keyword()) :: result()
  def fetch_catalog(opts \\ []) do
    with {:ok, repository, limits} <- Settings.authority(opts),
         {:ok, token} <- Transport.require_token(opts) do
      state = Settings.initial_state(opts, limits)

      # Per-member labels are what resolve each root's epic/wave counts, and
      # they are the expensive part of this query (#1766). The caller decides
      # when to buy them; a plain read stays on the 1-point variant.
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

  @spec fetch_selected_root(TrackerIdentity.t(), keyword()) :: result()
  def fetch_selected_root(root, opts \\ []) do
    with {:ok, repository, limits} <- Settings.authority(opts),
         {:ok, requested_root} <- Settings.requested_root(root, repository),
         {:ok, token} <- Transport.require_token(opts) do
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
end
