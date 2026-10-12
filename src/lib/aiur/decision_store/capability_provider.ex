defmodule Aiur.DecisionStore.CapabilityProvider do
  @moduledoc "Read-only Command availability; credentials are classified and never reported."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider

  @impl true
  def capability_ids, do: ~w(commands.read commands.answer commands.supervisor_api)

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    lookup = Keyword.get(opts, :lookup_fun, &Process.whereis/1)
    http = Provider.http(context, opts)
    read = read(lookup.(Aiur.DecisionStore), http)
    token = Keyword.get_lazy(opts, :token, fn -> System.get_env("AIUR_SUPERVISOR_TOKEN") end)

    %{
      "commands.read" => read,
      "commands.answer" => answer(context, read, lookup),
      "commands.supervisor_api" => supervisor(Aiur.SupervisorToken.classify(token), http)
    }
  end

  defp read(nil, _http), do: %{state: :unavailable, reason: :not_running}
  defp read(_pid, %{state: :available}), do: %{state: :available}
  defp read(_pid, _http), do: Provider.dependency("api.http")

  defp answer(_context, %{state: state} = read, _lookup) when state != :available, do: read

  defp answer(context, _read, lookup) do
    case Provider.writable(context) do
      false -> %{state: :unavailable, reason: :disabled}
      :unknown -> %{state: :unknown, reason: :unknown}
      true -> if lookup.(:"Elixir.Aiur.Orchestrator"), do: %{state: :available, version: 1}, else: Provider.dependency("orchestration", :degraded)
    end
  end

  defp supervisor(:missing, _http), do: %{state: :unavailable, reason: :not_configured}
  defp supervisor(:invalid, _http), do: %{state: :unknown, reason: :unknown}
  defp supervisor({:ok, _token}, %{state: :available}), do: %{state: :available}
  defp supervisor({:ok, _token}, _http), do: Provider.dependency("api.http")
end
