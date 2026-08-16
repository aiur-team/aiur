defmodule Aiur.BuildOrder.GitHubGraph.Pager do
  @moduledoc false

  alias Aiur.BuildOrder.GitHubGraph.{Connection, Endpoint, Queries, Request, Settings}
  alias Aiur.BuildOrder.GitHubGraph.Settings.Paging
  alias Aiur.TrackerIdentity

  @spec catalog(map(), map()) :: {:ok, [map()], map()} | {:error, atom(), map()}
  def catalog(paging, state) do
    query = Queries.catalog(member_labels?: paging.member_labels?)

    case Request.page(state, paging.token, query, Settings.catalog_variables(paging)) do
      {:ok, body, state} -> catalog_response(body, paging, state)
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  @spec selected(map(), map()) :: {:ok, map(), [map()], map()} | {:error, atom(), map()}
  def selected(paging, state) do
    case Request.page(state, paging.token, Queries.selected(), Settings.selected_variables(paging)) do
      {:ok, body, state} -> selected_response(body, paging, state)
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp catalog_response(body, paging, state) do
    with {:ok, connection} <- Connection.catalog(body),
         {:ok, nodes, total, page_info} <- Connection.parse(connection) do
      page_result(advance(paging, nodes, total, page_info, state), &catalog/2)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp selected_response(body, paging, state) do
    with {:ok, fetched_root, connection} <- Connection.selected(body),
         {:ok, paging} <- selected_root_page(paging, fetched_root),
         {:ok, nodes, total, page_info} <- Connection.parse(connection) do
      case advance(paging, nodes, total, page_info, state) do
        {:next, paging, state} -> selected(paging, state)
        {:ok, nodes, state} -> {:ok, paging.root, nodes, state}
        {:error, reason, state} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp page_result({:next, paging, state}, fun), do: fun.(paging, state)
  defp page_result({:ok, nodes, state}, _fun), do: {:ok, nodes, state}
  defp page_result({:error, reason, state}, _fun), do: {:error, reason, state}

  defp advance(paging, nodes, total, page_info, state) do
    case remember_total(paging, total) do
      {:ok, paging} -> advance_with_total(paging, nodes, total, page_info, state)
      :error -> {:error, :pagination_mismatch, state}
    end
  end

  defp advance_with_total(paging, nodes, total, page_info, state) do
    paging = %{paging | nodes: paging.nodes ++ nodes}

    case page_status(paging, total, page_info, state) do
      :overflow -> {:error, overflow_code(paging), state}
      :page_budget_exhausted -> {:error, :page_budget_exhausted, state}
      :complete -> {:ok, paging.nodes, state}
      :next -> advance_cursor(paging, page_info, state)
      :pagination_mismatch -> {:error, :pagination_mismatch, state}
    end
  end

  defp remember_total(%Paging{expected_total: nil} = paging, total), do: {:ok, %{paging | expected_total: total}}
  defp remember_total(%Paging{expected_total: total} = paging, total), do: {:ok, paging}
  defp remember_total(%Paging{}, _total), do: :error

  defp page_status(paging, total, page_info, state) do
    cond do
      page_overflow?(paging, total, page_info) ->
        :overflow

      page_info.has_next? ->
        continued_page_status(paging, total, state)

      length(paging.nodes) == total ->
        :complete

      true ->
        :pagination_mismatch
    end
  end

  defp continued_page_status(paging, total, state) do
    cond do
      length(paging.nodes) >= total -> :pagination_mismatch
      state.pages >= paging.limits.page_budget -> :page_budget_exhausted
      true -> :next
    end
  end

  defp page_overflow?(paging, total, page_info) do
    total > paging.limit or too_many_nodes?(paging, page_info)
  end

  defp too_many_nodes?(paging, page_info) do
    length(paging.nodes) > paging.limit or (page_info.has_next? and length(paging.nodes) >= paging.limit)
  end

  defp advance_cursor(paging, %{end_cursor: cursor}, state) when is_binary(cursor) and byte_size(cursor) > 0 do
    if MapSet.member?(paging.seen_cursors, cursor) do
      {:error, :pagination_mismatch, state}
    else
      {:next, %{paging | cursor: cursor, seen_cursors: MapSet.put(paging.seen_cursors, cursor)}, state}
    end
  end

  defp advance_cursor(_paging, _page_info, state), do: {:error, :pagination_mismatch, state}
  defp overflow_code(%Paging{root_number: nil}), do: :catalog_overflow
  defp overflow_code(%Paging{}), do: :member_overflow

  defp selected_root_page(%Paging{root: nil, requested_root: requested_root} = paging, fetched_root) do
    if requested_root?(fetched_root, requested_root, paging.repository) do
      {:ok, %{paging | root: fetched_root, root_fingerprint: root_fingerprint(fetched_root)}}
    else
      {:error, :invalid_root}
    end
  end

  defp selected_root_page(%Paging{} = paging, fetched_root) do
    if requested_root?(fetched_root, paging.requested_root, paging.repository) and
         root_fingerprint(fetched_root) == paging.root_fingerprint do
      {:ok, paging}
    else
      {:error, :pagination_mismatch}
    end
  end

  defp requested_root?(fetched_root, requested_root, repository) do
    case Endpoint.node_identity(fetched_root, repository) do
      {%TrackerIdentity{} = fetched, nil} ->
        Endpoint.same?(fetched, requested_root) and fetched.identifier == requested_root.identifier

      _ ->
        false
    end
  end

  defp root_fingerprint(root), do: Map.drop(root, ["subIssues"])
end
