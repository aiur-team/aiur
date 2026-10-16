defmodule AiurWeb.Experiments.Source do
  @moduledoc "Read adapter for the experiments page; all data comes through the experiments facade."

  alias AiurWeb.Experiments.ViewModel

  @spec index() :: {:ok, [map()]} | {:error, :store_unreadable}
  def index do
    catalog = facade().metric_catalog().metrics

    case facade().list() do
      {:ok, summaries} -> summaries |> Enum.reduce_while({:ok, []}, &hydrate(&1, &2, catalog)) |> order()
      {:error, _reason} -> {:error, :store_unreadable}
    end
  end

  defp hydrate(summary, {:ok, items}, catalog) do
    case facade().fetch(summary.id) do
      {:ok, detail} -> {:cont, {:ok, [ViewModel.index_item(summary, detail, catalog) | items]}}
      {:error, _reason} -> {:halt, {:error, :store_unreadable}}
    end
  end

  @spec detail(String.t()) :: {:ok, map()} | {:error, :not_found | :store_unreadable}
  def detail(id) do
    case facade().fetch(id) do
      {:ok, detail} -> {:ok, detail |> ViewModel.detail(facade().metric_catalog().metrics) |> Map.put(:id, id)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :store_unreadable}
    end
  end

  @spec status() :: map()
  def status do
    case facade().status() do
      %{store: {:error, :disabled}} = status -> status
      %{store: {:error, _reason}} = status -> %{status | store: {:error, :store_unreadable}}
      status -> status
    end
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: facade().subscribe()

  defp order({:ok, items}), do: {:ok, ViewModel.order(items)}
  defp order(error), do: error

  defp facade, do: Application.get_env(:aiur, :experiments_facade, Aiur.Experiments)
end
