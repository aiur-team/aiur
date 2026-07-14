defmodule Aiur.DecisionApi.LegacyPagination do
  @moduledoc false

  alias Aiur.DecisionQuery

  @default_limit 50
  @maximum_limit 200
  @maximum_offset 1_000_000
  @fields ~w(authority blocking cursor kind lifecycle limit offset search ticket)

  @spec list(map(), GenServer.server()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  def list(params, store) when is_map(params) do
    with {:ok, normalized} <- normalize(params) do
      if Map.has_key?(normalized, "cursor") do
        cursor_list(normalized, store)
      else
        offset_list(normalized, store)
      end
    end
  end

  defp cursor_list(params, store) do
    if Map.has_key?(params, "offset") do
      {:error, {:invalid_query, {:pagination, :cursor_conflicts_with_offset}}}
    else
      DecisionQuery.list(params, store: store)
    end
  end

  defp offset_list(params, store) do
    with {:ok, request} <- legacy_request(params),
         {:ok, page} <- collect(request.query, store, request, nil, []) do
      {:ok, legacy_page(page, request)}
    end
  end

  defp legacy_request(params) do
    with :ok <- reject_cursor_only_filters(params),
         {:ok, limit} <- bounded_integer(Map.get(params, "limit"), @default_limit, 1, @maximum_limit, :limit),
         {:ok, offset} <- bounded_integer(Map.get(params, "offset"), 0, 0, @maximum_offset, :offset),
         {:ok, query} <- DecisionQuery.Params.parse(Map.take(params, ["authority", "blocking", "kind", "ticket"])) do
      {:ok, %{limit: limit, offset: offset, remaining_offset: offset, query: query}}
    end
  end

  defp collect(query, store, %{remaining_offset: offset, limit: limit} = request, cursor, decisions) do
    remaining = limit - length(decisions)
    page_limit = min(100, max(1, offset + remaining))

    params =
      query
      |> Map.put(:limit, page_limit)
      |> maybe_put_cursor(cursor)

    with {:ok, page} <- DecisionQuery.list(params, store: store, ordering: :current) do
      {skipped, visible} = Enum.split(page.decisions, min(offset, length(page.decisions)))
      decisions = decisions ++ Enum.take(visible, remaining)
      request = %{request | remaining_offset: offset - length(skipped)}

      continue_or_finish(page, query, store, request, cursor, decisions)
    end
  end

  defp continue_or_finish(page, query, store, request, _cursor, decisions) do
    if page.partial_results? or length(decisions) >= request.limit or is_nil(page.pagination.next_cursor) do
      {:ok, %{page | decisions: decisions}}
    else
      collect(query, store, request, page.pagination.next_cursor, decisions)
    end
  end

  defp legacy_page(page, %{limit: limit, offset: requested_offset}) do
    next_offset =
      if is_binary(page.pagination.next_cursor) and page.decisions != [] do
        requested_offset + length(page.decisions)
      end

    pagination =
      page.pagination
      |> Map.put(:limit, limit)
      |> Map.put(:offset, requested_offset)
      |> Map.put(:next_offset, next_offset)

    %{page | pagination: pagination}
  end

  defp maybe_put_cursor(params, nil), do: params
  defp maybe_put_cursor(params, cursor), do: Map.put(params, :cursor, cursor)

  defp reject_cursor_only_filters(params) do
    case Enum.find(["lifecycle", "search"], &Map.has_key?(params, &1)) do
      nil -> :ok
      field -> {:error, {:invalid_query, {String.to_atom(field), :cursor_required}}}
    end
  end

  defp normalize(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(raw_key),
           :ok <- validate_key(key),
           :ok <- reject_duplicate(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_query, reason}}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, {:field, :invalid}}
  defp validate_key(key) when key in @fields, do: :ok
  defp validate_key(key), do: {:error, {:field, key, :unknown}}

  defp reject_duplicate(params, key) do
    if Map.has_key?(params, key), do: {:error, {:field, key, :duplicate}}, else: :ok
  end

  defp bounded_integer(nil, default, _minimum, _maximum, _field), do: {:ok, default}

  defp bounded_integer(value, _default, minimum, maximum, field) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer >= minimum and integer <= maximum -> {:ok, integer}
      _invalid -> {:error, {:invalid_query, {field, :invalid}}}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp parse_integer(_value), do: nil
end
