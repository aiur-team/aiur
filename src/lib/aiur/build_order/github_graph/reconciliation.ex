defmodule Aiur.BuildOrder.GitHubGraph.Reconciliation do
  @moduledoc """
  The rare GraphQL re-convergence of the event-sourced Build Order catalog.

  The catalog is normally projected from `Aiur.GitHub.ResourceStore`, which
  every delivery and Aiur-originated mutation keeps current at zero GraphQL
  cost (#2313). Deliveries can be dropped — the webhook admission gate fails
  open on a 5 s timeout — so an event-sourced projection needs a way to
  re-converge. This module runs at boot, on explicit refresh and degradation,
  and on a bounded daemon-owned safety interval in every delivery mode. A
  healthy stream does not prove that membership deliveries were received.

  It re-reads the `build_order_catalog` query (the labelled variant, so member
  labels resolve the epic/wave counts) and writes the result back into the
  store the projection reads from:

    * each root and member becomes an `:issue` body (REST shape, so it matches
      what a delivery deposits) plus an `:issue_labels` set;
    * each root→member pair becomes a `:sub_issue` edge.

  The repo's membership is replaced as one fenced set. A webhook edge write
  after the query starts rejects the stale replacement; the next bounded
  reconciliation retries. Readers never see a clear-then-redeposit gap. Shared
  `:issue`/`:issue_labels` entries are left in place and only refreshed, because
  other consumers read them and their own events keep them current.

  The store writes publish `Aiur.GitHub.ResourceEvents`, which is what wakes
  `Aiur.BuildOrder.GraphProjection` to rebuild the catalog from the store.
  """

  alias Aiur.BuildOrder.GitHubGraph.{Connection, Pager, Settings}
  alias Aiur.GitHub.{ResourceStore, Transport}

  @doc """
  Re-converges the store's Build Order graph from GitHub.

  Options are the same as `Aiur.BuildOrder.GitHubGraph.fetch_catalog/1`
  (`:repository`, `:request_fun`, root/page/call limits).
  """
  @spec run(keyword()) :: {:ok, :reconciled, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, repository, limits} <- Settings.authority(opts),
         {:ok, token} <- Transport.require_token(opts),
         {:ok, fence} <-
           ResourceStore.membership_snapshot(elem(repository, 0), elem(repository, 1)) do
      state = Settings.initial_state(opts, limits)

      paging =
        repository
        |> Settings.new_paging(token, limits, limits.root_limit)
        |> Map.put(:member_labels?, true)

      case Pager.catalog(paging, state) do
        {:ok, nodes, _state} ->
          reconcile_nodes(repository, nodes, fence)

        {:error, reason, _state} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_nodes(repository, nodes, fence) do
    with :ok <- require_complete_membership(nodes),
         :ok <- deposit_catalog(repository, nodes, fence),
         do: {:ok, :reconciled, %{roots: length(nodes)}}
  end

  # The catalog query fetches at most 100 members per root. A partial nested
  # connection cannot replace the complete membership set held from webhooks.
  defp require_complete_membership(nodes) do
    if Enum.all?(nodes, &complete_membership?/1),
      do: :ok,
      else: {:error, :incomplete_membership}
  end

  defp complete_membership?(node) do
    case Connection.parse(Map.get(node, "subIssues")) do
      {:ok, members, total, %{has_next?: false}} -> length(members) == total
      _partial_or_invalid -> false
    end
  end

  # -- deposit --------------------------------------------------------------

  defp deposit_catalog({owner, repo} = repository, nodes, fence) do
    edges = Enum.flat_map(nodes, &root_edges(&1, repository))
    ResourceStore.replace_membership(owner, repo, fence, edges)
  end

  defp root_edges(node, repository) do
    deposit_issue(node, repository)

    case Connection.parse(Map.get(node, "subIssues")) do
      {:ok, members, _total, _page_info} ->
        Enum.flat_map(members, &member_edge(&1, node, repository))

      _invalid ->
        []
    end
  end

  defp member_edge(member, root, repository) do
    deposit_issue(member, repository)

    with parent when is_integer(parent) <- positive_number(Map.get(root, "number")),
         sub when is_integer(sub) <- positive_number(Map.get(member, "number")) do
      full_name = repo_string(repository)

      edge = %{
        "present" => true,
        "parent_issue_number" => parent,
        "sub_issue_number" => sub,
        "parent_issue_repo" => full_name,
        "sub_issue_repo" => full_name
      }

      [{"#{parent}:#{sub}", edge}]
    else
      _invalid -> []
    end
  end

  defp deposit_issue(node, repository) do
    with number when is_integer(number) <- positive_number(Map.get(node, "number")) do
      full_name = repo_string(repository)
      body = issue_body(node, full_name)

      ResourceStore.put_resource(
        ResourceStore.key_for_repo(:issue, full_name, number),
        body,
        source: :reconciliation,
        version: Map.get(body, "updated_at"),
        etag: :derive
      )

      deposit_labels(full_name, number, node)
    end

    :ok
  end

  defp deposit_labels(full_name, number, node) do
    labels =
      case Connection.parse(Map.get(node, "labels")) do
        {:ok, label_nodes, _total, _page_info} ->
          Enum.map(label_nodes, &%{"name" => Map.get(&1, "name")})

        _invalid ->
          []
      end

    if labels != [] do
      ResourceStore.put_resource(
        ResourceStore.key_for_repo(:issue_labels, full_name, number),
        labels,
        source: :reconciliation,
        version: Map.get(node, "updatedAt"),
        etag: :derive
      )
    end

    :ok
  end

  # GraphQL node -> the REST-ish issue body the store holds for `:issue`. Every
  # other writer of this type (a delivery, a mutation response) files REST
  # shape, so a reconciliation that filed the raw camelCase node would hand the
  # next reader a body no other writer produces — the exact drift the store
  # exists to prevent. The keys are what `TrackerIdentity.from_github/3` and
  # `Aiur.BuildOrder.CatalogStore` read.
  defp issue_body(node, full_name) do
    %{
      "id" => Map.get(node, "databaseId"),
      "node_id" => Map.get(node, "id"),
      "number" => Map.get(node, "number"),
      "title" => Map.get(node, "title"),
      "html_url" => Map.get(node, "url"),
      "url" => Map.get(node, "url"),
      "state" => Map.get(node, "state"),
      "state_reason" => Map.get(node, "stateReason"),
      "created_at" => Map.get(node, "createdAt"),
      "updated_at" => Map.get(node, "updatedAt"),
      "repository_url" => repository_url(full_name),
      "labels" => []
    }
  end

  defp repository_url(full_name) do
    case String.split(full_name, "/") do
      [owner, repo] -> "https://api.github.com/repos/#{owner}/#{repo}"
      _other -> nil
    end
  end

  defp repo_string({owner, repo}), do: "#{owner}/#{repo}"

  defp positive_number(value) when is_integer(value) and value > 0, do: value

  defp positive_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp positive_number(_value), do: nil
end
