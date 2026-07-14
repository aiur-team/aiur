defmodule AiurWeb.OperatorControlCenter.DecisionProvider do
  @moduledoc """
  Dashboard-facing retained Decision reads.

  The provider is intentionally on-demand: callers request a selected detail,
  retained page, or canonical counts explicitly. It never expands the
  priority-bounded overview into the complete retained store during a normal
  dashboard mount.
  """

  alias Aiur.{DecisionMetrics, DecisionQuery}
  alias AiurWeb.OperatorControlCenter.DecisionPresenter

  @spec detail(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :store_unavailable | {:invalid_decision_id, atom()}}
  def detail(decision_id, opts \\ []) when is_list(opts) do
    with {:ok, result} <- DecisionQuery.get(decision_id, store: store(opts)) do
      {snapshots, latency_health} = latency_for(result.decision.decision_id, metrics(opts))

      case DecisionPresenter.present(result.decision) do
        [decision] ->
          {:ok,
           %{
             decision: DecisionPresenter.attach_latency([decision], snapshots, latency_health) |> hd(),
             scope: Map.put(result.scope, :label, "Exact retained Decision detail"),
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
    with {:ok, result} <- DecisionQuery.list(params, store: store(opts)) do
      {snapshots, latency_health} = latency_snapshots(metrics(opts))

      rows =
        result.decisions
        |> Enum.flat_map(&DecisionPresenter.present/1)
        |> DecisionPresenter.attach_latency(snapshots, latency_health)

      {:ok, %{result | decisions: rows}}
    end
  end

  def list(_params, _opts), do: {:error, {:invalid_query, {:params, :invalid_type}}}

  @spec counts(keyword()) :: {:ok, map()}
  def counts(opts \\ []) when is_list(opts), do: DecisionQuery.counts(store: store(opts))

  defp store(opts), do: Keyword.get(opts, :decision_store, Aiur.DecisionStore)
  defp metrics(opts), do: Keyword.get(opts, :decision_metrics, DecisionMetrics)

  defp latency_for(decision_id, metrics) do
    case safe_metrics_call(fn -> DecisionMetrics.snapshot(decision_id, metrics) end) do
      {:ok, snapshot} when is_map(snapshot) -> {%{decision_id => snapshot}, :ok}
      {:error, :not_found} -> {%{}, :ok}
      _unavailable -> {%{}, :unavailable}
    end
  end

  defp latency_snapshots(metrics) do
    case safe_metrics_call(fn -> DecisionMetrics.snapshots(metrics) end) do
      snapshots when is_map(snapshots) -> {snapshots, :ok}
      _unavailable -> {%{}, :unavailable}
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
