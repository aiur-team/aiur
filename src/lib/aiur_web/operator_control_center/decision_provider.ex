defmodule AiurWeb.OperatorControlCenter.DecisionProvider do
  @moduledoc """
  Dashboard-facing retained Decision reads.

  The provider is intentionally on-demand: callers request a selected detail,
  retained page, or canonical counts explicitly. It never expands the
  priority-bounded overview into the complete retained store during a normal
  dashboard mount.
  """

  alias Aiur.Commands
  alias AiurWeb.OperatorControlCenter.DecisionPresenter

  @spec detail(String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :store_unavailable
             | {:indeterminate, map()}
             | {:invalid_decision_id, atom()}}
  def detail(decision_id, opts \\ []) when is_list(opts) do
    with {:ok, result} <- Commands.query_get(decision_id, store: store(opts)) do
      {snapshots, latency_health} = latency_for(result.decision.decision_id, metrics(opts))

      case DecisionPresenter.present(result.decision) do
        [decision] ->
          {:ok,
           %{
             decision: DecisionPresenter.attach_latency([decision], snapshots, latency_health) |> hd() |> Map.put(:audit_history, audit_history(decision_id, store(opts))),
             scope: Map.put(result.scope, :label, "Exact Command detail"),
             health: result.health
           }}

        [] ->
          {:error, :store_unavailable}
      end
    end
  end

  @spec list(map(), keyword()) :: {:ok, map()} | {:error, {:invalid_query, term()}}
  def list(params \\ %{}, opts \\ [])

  def list(params, opts) when is_map(params) and is_list(opts) do
    with :ok <- validate_requester(params),
         {:ok, result} <- Commands.query_list(Map.drop(params, ["requester", :requester]), store: store(opts)) do
      {snapshots, latency_health} = latency_for_ids(Enum.map(result.decisions, & &1.decision_id), metrics(opts))

      rows =
        result.decisions
        |> Enum.flat_map(&DecisionPresenter.present/1)
        |> DecisionPresenter.attach_latency(snapshots, latency_health)

      {:ok, filter_requester(%{result | decisions: rows}, Map.get(params, "requester", Map.get(params, :requester)))}
    end
  end

  def list(_params, _opts), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  defp validate_requester(params) do
    case Map.get(params, "requester", Map.get(params, :requester)) do
      value when value in [nil, "executor"] -> :ok
      _value -> {:error, {:invalid_query, {:requester, :invalid_value}}}
    end
  end

  # Requester has no retained-store index: preserve the underlying page cursor,
  # and expose only a page-scoped count, never the unfiltered total as its total.
  defp filter_requester(result, "executor") do
    rows = Enum.filter(result.decisions, &DecisionPresenter.executor?/1)
    partial? = result.partial_results? or result.health.partial?

    result
    |> Map.put(:decisions, rows)
    |> Map.put(:requester_page, %{count: if(partial?, do: nil, else: length(rows)), partial?: partial?})
    |> Map.update!(:pagination, &Map.put(&1, :total, nil))
  end

  defp filter_requester(result, _requester), do: result

  @spec counts(keyword()) :: {:ok, map()}
  def counts(opts \\ []) when is_list(opts), do: Commands.query_counts(store: store(opts))

  defp audit_history(id, store) do
    case Commands.audit_history(id, store) do
      {:ok, entries} -> Enum.map(entries, &audit_entry/1)
      {:error, _reason} -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  # Only display-safe fact fields cross into the dashboard; never forward raw event data.
  defp audit_entry(%{type: type, occurred_at: at, data: data}) do
    %{type: type, at: at, cause: Map.get(data, :cause)}
  end

  defp audit_entry(%{event_type: _type, occurred_at: at}), do: %{type: :unknown, at: at, cause: nil}
  defp audit_entry(%{created_at: at}), do: %{type: :requested, at: at, cause: nil}

  defp store(opts), do: Keyword.get(opts, :decision_store, Commands.default_store())
  defp metrics(opts), do: Keyword.get(opts, :decision_metrics, Commands.default_metrics())

  defp latency_for(decision_id, metrics) do
    case safe_metrics_call(fn -> Commands.metrics_snapshot(decision_id, metrics) end) do
      {:ok, snapshot} when is_map(snapshot) -> {%{decision_id => snapshot}, :ok}
      {:error, :not_found} -> {%{}, :ok}
      _unavailable -> {%{}, :unavailable}
    end
  end

  defp latency_for_ids(decision_ids, metrics) do
    Enum.reduce_while(decision_ids, {%{}, :ok}, fn decision_id, {snapshots, health} ->
      next_latency_snapshot(decision_id, metrics, snapshots, health)
    end)
  end

  defp next_latency_snapshot(decision_id, metrics, snapshots, health) do
    case safe_metrics_call(fn -> Commands.metrics_snapshot(decision_id, metrics) end) do
      {:ok, snapshot} when is_map(snapshot) -> {:cont, {Map.put(snapshots, decision_id, snapshot), health}}
      {:error, :not_found} -> {:cont, {snapshots, health}}
      _unavailable -> {:halt, {snapshots, :unavailable}}
    end
  end

  defp safe_metrics_call(fun) do
    fun.()
  rescue
    _error -> :unavailable
  catch
    :exit, _reason -> :unavailable
  end
end
