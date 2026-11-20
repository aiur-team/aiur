defmodule Aiur.DecisionQuery do
  @moduledoc """
  Bounded retained-Decision read contracts.

  This module deliberately reads through `DecisionStore`: its current projection
  remains the persistence authority. The priority overview and retained query
  are different contracts. Retained pages use immutable creation time and
  canonical ID ordering so a lifecycle transition cannot move an item across a
  cursor boundary.
  """

  alias Aiur.DecisionQuery.{Cursor, Params, StoreReader}
  alias Aiur.DecisionStore

  @default_store DecisionStore

  # Retained counts are fleet-wide index facts. A ticket-scoped read must not
  # publish them: they would describe Commands the caller may not enumerate.
  @count_keys [
    :open,
    :blocking,
    :total,
    :awaiting,
    :awaiting_blocking,
    :deferred,
    :needs_you,
    :needs_you_blocking,
    :with_executor,
    :from_executor,
    :needs_you_by_ticket
  ]

  @doc false
  @spec default_store() :: module()
  def default_store, do: @default_store

  @doc "Returns one exact retained Decision without consulting the overview window."
  @spec get(String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :store_unavailable
             | {:indeterminate, map()}
             | {:invalid_decision_id, atom()}}
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
      read_page(apply_label_scope(query, opts), opts)
    end
  end

  def list(_params, _opts), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  @doc """
  Returns one retained page narrowed to an explicit ticket set.

  The set is applied inside the store query, not to the returned page, so the
  counts, total, and cursor continuation describe only the allowed tickets.
  An out-of-scope ticket filter is therefore empty rather than revealing that
  other Commands exist. A `labels` query parameter narrows the page further: it
  keeps only the tickets in the set that currently carry one of those labels, so
  request labels can never widen the set a caller was granted.
  """
  @spec list_scoped(map(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, {:invalid_query, term()}}
  def list_scoped(params, tickets, opts \\ [])

  def list_scoped(params, tickets, opts) when is_map(params) and is_list(opts) do
    with {:ok, ticket_set} <- ticket_set(tickets),
         {:ok, query} <- Params.parse(params) do
      # Scoped reads serve creator inboxes, which never show Executor-only Commands.
      read_page(query |> Map.merge(%{tickets: ticket_set, creator_inbox: true}) |> narrow_by_labels(opts), opts)
    end
  end

  def list_scoped(_params, _tickets, _opts), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  defp read_page(query, opts) do
    query = Map.put(query, :ordering, ordering(opts))

    case StoreReader.read_query(query, store(opts)) do
      {:ok, snapshot, health} -> {:ok, retained_page(snapshot, query, health)}
      {:error, :store_unavailable} -> {:ok, unavailable_page(query)}
    end
  end

  defp ticket_set(%MapSet{} = tickets), do: {:ok, downcase_set(tickets)}

  defp ticket_set(tickets) when is_list(tickets) do
    if Enum.all?(tickets, &is_binary/1), do: {:ok, downcase_set(tickets)}, else: invalid_ticket_set()
  end

  defp ticket_set(_tickets), do: invalid_ticket_set()

  defp downcase_set(tickets) do
    MapSet.new(tickets, fn ticket -> ticket |> String.trim() |> String.downcase() end)
  end

  defp invalid_ticket_set, do: {:error, {:invalid_query, {:tickets, :invalid}}}

  @doc """
  The tickets an explicit set and a label scope authorize together.

  A label scope contributes the tickets the tracker currently observes to carry
  one of `labels`. When no usable observation exists the label scope contributes
  nothing, so a caller can never widen its scope by asking for a label Aiur has
  not seen.
  """
  @spec scoped_tickets(Enumerable.t(), Enumerable.t(), keyword()) :: MapSet.t(String.t())
  def scoped_tickets(tickets, labels, opts \\ []) do
    MapSet.union(ticket_set!(tickets), label_tickets(labels, opts))
  end

  defp ticket_set!(%MapSet{} = tickets), do: downcase_set(tickets)
  defp ticket_set!(tickets) when is_list(tickets), do: downcase_set(tickets)

  defp apply_label_scope(%{labels: labels} = query, opts) when is_list(labels) and labels != [] do
    tickets = Map.get(query, :tickets) || MapSet.new()
    Map.put(query, :tickets, MapSet.union(tickets, label_tickets(labels, opts)))
  end

  defp apply_label_scope(query, _opts), do: query

  # A request label narrows a scoped read; it never widens the ticket set. A
  # label the grant did not authorize resolves to tickets the set does not
  # contain, so the page is empty instead of exposing another game's Commands.
  defp narrow_by_labels(%{labels: labels} = query, opts) when is_list(labels) and labels != [] do
    tickets = Map.get(query, :tickets) || MapSet.new()
    Map.put(query, :tickets, MapSet.intersection(tickets, label_tickets(labels, opts)))
  end

  defp narrow_by_labels(query, _opts), do: query

  @doc false
  @spec label_tickets(Enumerable.t(), keyword()) :: MapSet.t(String.t())
  def label_tickets(labels, opts \\ []) do
    label_set = MapSet.new(labels, &(to_string(&1) |> String.downcase()))

    if MapSet.size(label_set) == 0 do
      MapSet.new()
    else
      label_set |> labelled_tickets(observe_labels(opts))
    end
  end

  defp observe_labels(opts) do
    fun = Keyword.get(opts, :labels_fun, fn -> Aiur.Tracker.open_issue_labels(120_000) end)

    case fun.() do
      {:ok, observed, _observed_at} when is_map(observed) -> observed
      _unavailable -> %{}
    end
  rescue
    _error -> %{}
  catch
    :exit, _reason -> %{}
  end

  defp labelled_tickets(label_set, observed) when is_map(observed) do
    Enum.reduce(observed, MapSet.new(), fn {identifier, observation}, acc ->
      ticket_labels = observation |> labels_of() |> Enum.map(&String.downcase/1)

      if Enum.any?(ticket_labels, &MapSet.member?(label_set, &1)) do
        MapSet.put(acc, identifier |> to_string() |> String.downcase())
      else
        acc
      end
    end)
  end

  defp labels_of(%{} = observation) do
    case Map.get(observation, :labels) || Map.get(observation, "labels") do
      labels when is_list(labels) -> Enum.filter(labels, &is_binary/1)
      _missing -> []
    end
  end

  defp labels_of(_observation), do: []

  @doc false
  @spec legacy_page(map(), non_neg_integer(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, {:invalid_query, term()}}
  def legacy_page(query, offset, limit, opts \\ [])

  def legacy_page(query, offset, limit, opts)
      when is_map(query) and is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0 and
             is_list(opts) do
    query = Map.merge(query, %{cursor: nil, limit: limit, ordering: :current})

    case StoreReader.read_legacy_page(query, offset, limit, store(opts)) do
      {:ok, snapshot, health} -> {:ok, retained_page(snapshot, query, health)}
      {:error, :store_unavailable} -> {:ok, unavailable_page(query)}
      {:error, :invalid_query} -> {:error, {:invalid_query, :legacy_page}}
    end
  end

  def legacy_page(_query, _offset, _limit, _opts), do: {:error, {:invalid_query, :legacy_page}}

  @doc "Returns canonical retained open and blocking counts with retention health."
  @spec counts(keyword()) :: {:ok, map()}
  def counts(opts \\ []) when is_list(opts) do
    case StoreReader.read_counts(store(opts)) do
      {:ok, counts, health} ->
        {:ok, Map.merge(counts, %{scope: scope(), health: health})}

      {:error, :store_unavailable} ->
        {:ok,
         %{
           needs_you: nil,
           needs_you_blocking: nil,
           with_executor: nil,
           from_executor: nil,
           needs_you_by_ticket: nil,
           open: nil,
           blocking: nil,
           total: nil,
           awaiting: nil,
           awaiting_blocking: nil,
           deferred: nil,
           scope: scope(),
           health: StoreReader.unavailable_health()
         }}
    end
  end

  defp store(opts), do: Keyword.get(opts, :store, @default_store)
  defp ordering(opts), do: if(Keyword.get(opts, :ordering) == :current, do: :current, else: :audit)

  defp next_cursor(_key, false), do: nil
  defp next_cursor(nil, true), do: nil

  defp next_cursor({created_at, decision_id}, true) do
    %{created_at: DateTime.from_unix!(-created_at, :microsecond), decision_id: decision_id}
    |> Cursor.encode()
  end

  defp retained_page(snapshot, query, health) do
    partial? = health.partial? or Map.get(snapshot, :partial?, false)
    partial_reason = partial_reason(health, snapshot)

    %{
      decisions: snapshot.decisions,
      scope: scope(),
      health: health,
      partial_results?: partial?,
      partial_reason: partial_reason,
      pagination: %{
        limit: query.limit,
        cursor: query.cursor && Cursor.encode(query.cursor),
        next_cursor: next_cursor(Map.get(snapshot, :next_key), snapshot.has_next?),
        total: snapshot.total,
        partial_reason: partial_reason,
        label: pagination_label(query.limit, snapshot.has_next?, partial_reason)
      },
      filters: Map.take(query, [:authority, :blocking, :kind, :labels, :lifecycle, :route, :search, :ticket]),
      counts: counts(snapshot.counts, query)
    }
  end

  defp counts(_counts, %{tickets: %MapSet{}}), do: Map.new(@count_keys, &{&1, nil})
  defp counts(counts, _query), do: counts

  defp unavailable_page(query) do
    %{
      decisions: [],
      scope: scope(),
      health: StoreReader.unavailable_health(),
      partial_results?: true,
      partial_reason: :retained_store_unavailable,
      pagination: %{
        limit: query.limit,
        cursor: query.cursor && Cursor.encode(query.cursor),
        next_cursor: nil,
        total: nil,
        partial_reason: :retained_store_unavailable,
        label: "Retained Decision page unavailable"
      },
      filters: Map.take(query, [:authority, :blocking, :kind, :lifecycle, :route, :search, :ticket])
    }
  end

  defp scope, do: %{kind: :retained, label: "All retained decisions"}

  defp partial_reason(%{reason: :retained_store_partial}, _snapshot), do: :retained_store_partial

  defp partial_reason(_health, %{partial_reason: :retained_query_scan_capped}),
    do: :retained_query_scan_capped

  defp partial_reason(_health, _snapshot), do: nil

  defp pagination_label(limit, _has_next?, :retained_store_partial) do
    "Partial retained Decision page of up to #{limit}; retained audit data is corrupt, so refining filters cannot make results complete"
  end

  defp pagination_label(limit, _has_next?, :retained_query_scan_capped) do
    "Partial retained Decision page of up to #{limit}; refine the filter for complete results"
  end

  defp pagination_label(limit, true, nil) do
    "Retained Decision page of up to #{limit}; more results are available"
  end

  defp pagination_label(limit, false, nil), do: "Final retained Decision page of up to #{limit}"
end
