defmodule AiurWeb.OperatorControlCenter.DecisionPath do
  @moduledoc false

  @filters [:open, :blocking, :undelivered, :supervisor, :resolved, :superseded]
  @query_keys [:cursor, :search]

  @spec inbox(atom()) :: String.t()
  def inbox(filter), do: inbox(filter, %{})

  @spec inbox(atom(), map()) :: String.t()
  def inbox(filter, query) when is_map(query), do: with_query("/decisions", filter, query)

  @spec detail(String.t(), atom()) :: String.t()
  def detail(decision_id, filter), do: detail(decision_id, filter, %{})

  @spec detail(String.t(), atom(), map()) :: String.t()
  def detail(decision_id, filter, query) when is_binary(decision_id) and is_map(query) do
    decision_id = URI.encode(decision_id, &URI.char_unreserved?/1)
    with_query("/decisions/#{decision_id}", filter, query)
  end

  defp with_query(path, filter, query) do
    params =
      query
      |> Map.take(@query_keys)
      |> Enum.reduce(%{}, fn
        {key, value}, params when is_binary(value) and value != "" -> Map.put(params, Atom.to_string(key), value)
        _entry, params -> params
      end)
      |> maybe_put_filter(filter)

    if map_size(params) == 0, do: path, else: path <> "?" <> URI.encode_query(params)
  end

  defp maybe_put_filter(params, filter) when filter in @filters,
    do: Map.put(params, "filter", Atom.to_string(filter))

  defp maybe_put_filter(params, _filter), do: params
end
