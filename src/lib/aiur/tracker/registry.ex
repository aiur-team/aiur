defmodule Aiur.Tracker.Registry do
  @moduledoc "Registered tracker adapters. Unknown and nil kinds retain the configured legacy fallback."

  @spec kinds() :: [String.t()]
  def kinds, do: adapters() |> Map.keys() |> Enum.sort()

  @spec adapter_for(String.t() | nil) :: module()
  def adapter_for(kind) do
    registered = adapters()
    Map.get_lazy(registered, kind, fn -> Map.fetch!(registered, Application.fetch_env!(:aiur, :tracker_fallback_kind)) end)
  end

  @spec config_module(String.t()) :: module() | nil
  def config_module(kind) do
    with {:ok, adapter} <- Map.fetch(adapters(), kind),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :config_module, 0) do
      adapter.config_module()
    else
      _ -> nil
    end
  end

  defp adapters, do: Application.fetch_env!(:aiur, :tracker_adapters)
end
