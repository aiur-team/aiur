defmodule Aiur.DecisionQuery do
  @moduledoc """
  Bounded retained-Decision read contracts.

  This module deliberately reads through `DecisionStore`: its current projection
  remains the persistence authority. The priority overview and retained query
  are different contracts. Retained pages use immutable creation time and
  canonical ID ordering so a lifecycle transition cannot move an item across a
  cursor boundary.
  """

  alias Aiur.Decision
  alias Aiur.DecisionQuery.{Params, StoreReader}

  @doc "Returns one exact retained Decision without consulting the overview window."
  @spec get(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :store_unavailable | {:invalid_decision_id, atom()}}
  def get(decision_id, opts \\ [])

  def get(decision_id, opts) when is_list(opts) do
    with {:ok, normalized_id} <- Params.normalize_decision_id(decision_id),
         {:ok, decision, health} <- StoreReader.read_one(normalized_id, store(opts)) do
      {:ok, %{decision: decision, scope: scope(), health: health}}
    end
  end

  def get(_decision_id, _opts), do: {:error, {:invalid_decision_id, :invalid_type}}

  @doc "Returns one stable, bounded retained-Decision page and its query metadata."
  @spec list(map(), keyword()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  def list(params \\ %{}, opts \\ [])

  def list(params, opts) when is_map(params) and is_list(opts) do
    with {:ok, query} <- Params.parse(params) do
      case StoreReader.read_all(store(opts)) do
        {:ok, decisions, health} -> {:ok, retained_page(decisions, query, health)}
        {:error, :store_unavailable} -> {:ok, unavailable_page(query)}
      end
    end
  end

  def list(_params, _opts), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  @doc "Returns canonical retained open and blocking counts with retention health."
  @spec counts(keyword()) :: {:ok, map()}
  def counts(opts \\ []) when is_list(opts) do
    case StoreReader.read_all(store(opts)) do
      {:ok, decisions, health} ->
        open = Enum.filter(decisions, &(&1.decision_status == :open))

        {:ok,
         %{
           open: length(open),
           blocking: Enum.count(open, & &1.blocking),
           scope: scope(),
           health: health
         }}

      {:error, :store_unavailable} ->
        {:ok, %{open: nil, blocking: nil, scope: scope(), health: StoreReader.unavailable_health()}}
    end
  end

  defp store(opts), do: Keyword.get(opts, :store, DecisionStore)

  defp matches?(%Decision{} = decision, query) do
    lifecycle_matches?(decision, query.lifecycle) and
      optional_match(query.ticket, decision.ticket.identifier) and
      search_matches?(decision, query.search)
  end

  defp lifecycle_matches?(_decision, nil), do: true
  defp lifecycle_matches?(decision, lifecycle), do: decision.decision_status == lifecycle

  defp optional_match(nil, _actual), do: true
  defp optional_match(expected, actual) when is_binary(actual), do: String.contains?(String.downcase(actual), String.downcase(expected))
  defp optional_match(_expected, _actual), do: false

  defp search_matches?(_decision, nil), do: true

  defp search_matches?(decision, search) do
    needle = String.downcase(search)
    String.contains?(String.downcase(decision.decision_id), needle) or optional_match(search, decision.ticket.identifier)
  end

  defp sort_key(%Decision{} = decision) do
    {DateTime.to_unix(decision.created_at, :microsecond), decision.decision_id}
  end

  defp after_cursor(decisions, nil), do: decisions
  defp after_cursor(decisions, cursor), do: Enum.filter(decisions, &(sort_key(&1) < cursor_key(cursor)))
  defp cursor_key(cursor), do: {DateTime.to_unix(cursor.created_at, :microsecond), cursor.decision_id}

  defp split_page(decisions, limit) do
    {Enum.take(decisions, limit), length(decisions) > limit}
  end

  defp next_cursor([], _has_next?), do: nil
  defp next_cursor(_items, false), do: nil

  defp next_cursor(items, true) do
    items
    |> List.last()
    |> cursor_for()
    |> encode_cursor()
  end

  defp cursor_for(%Decision{} = decision), do: %{created_at: decision.created_at, decision_id: decision.decision_id}

  defp retained_page(decisions, query, health) do
    retained = decisions |> Enum.filter(&matches?(&1, query)) |> Enum.sort_by(&sort_key/1, :desc)
    page = retained |> after_cursor(query.cursor) |> Enum.take(query.limit + 1)
    {items, has_next?} = split_page(page, query.limit)

    %{
      decisions: items,
      scope: scope(),
      health: health,
      partial_results?: health.partial?,
      pagination: %{
        limit: query.limit,
        cursor: query.cursor && encode_cursor(query.cursor),
        next_cursor: next_cursor(items, has_next?),
        total: length(retained),
        label: pagination_label(query.limit, has_next?)
      },
      filters: Map.take(query, [:lifecycle, :search, :ticket])
    }
  end

  defp unavailable_page(query) do
    %{
      decisions: [],
      scope: scope(),
      health: StoreReader.unavailable_health(),
      partial_results?: true,
      pagination: %{
        limit: query.limit,
        cursor: query.cursor && encode_cursor(query.cursor),
        next_cursor: nil,
        total: nil,
        label: "Retained Decision page unavailable"
      },
      filters: Map.take(query, [:lifecycle, :search, :ticket])
    }
  end

  defp encode_cursor(cursor) do
    cursor
    |> then(fn value -> %{"created_at" => DateTime.to_iso8601(value.created_at), "decision_id" => value.decision_id} end)
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp scope, do: %{kind: :retained, label: "All retained decisions"}

  defp pagination_label(limit, true), do: "Retained Decision page of up to #{limit}; more results are available"
  defp pagination_label(limit, false), do: "Final retained Decision page of up to #{limit}"
end
