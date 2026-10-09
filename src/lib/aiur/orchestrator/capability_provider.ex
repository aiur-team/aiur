defmodule Aiur.Orchestrator.CapabilityProvider do
  @moduledoc "Read-only orchestration and agent capability contributions."
  @behaviour Aiur.Capabilities.Provider
  alias Aiur.Capabilities.Provider
  alias Aiur.Orchestrator.SnapshotStore

  @impl true
  def capability_ids, do: ~w(orchestration instance.status agents.run agents.message)

  @impl true
  def capabilities(context), do: evaluate(context)

  @spec evaluate(Provider.context(), keyword()) :: map()
  def evaluate(context, opts \\ []) do
    orchestration = orchestration(opts)

    %{
      "orchestration" => orchestration,
      "instance.status" => if(orchestration.state == :available, do: %{state: :available}, else: Provider.dependency("orchestration", :degraded)),
      "agents.run" => if(orchestration.state == :unavailable, do: Provider.dependency("orchestration"), else: %{state: :available}),
      "agents.message" => message(context, opts, orchestration)
    }
  end

  defp orchestration(opts) do
    lookup = Keyword.get(opts, :lookup_fun, &Process.whereis/1)

    if lookup.(Aiur.Orchestrator) do
      case Keyword.get(opts, :snapshot_fun, fn -> SnapshotStore.read(Aiur.Orchestrator, 0) end).() do
        {:current, _snapshot, _meta} -> %{state: :available}
        {:stale, _snapshot, meta} -> %{state: :degraded, reason: :snapshot_stale, observed_at: meta.observed_at}
        :snapshot_unpublished -> %{state: :degraded, reason: :snapshot_unpublished}
        _ -> %{state: :unknown, reason: :unknown}
      end
    else
      %{state: :unavailable, reason: :not_running}
    end
  end

  defp message(context, opts, orchestration) do
    cond do
      Provider.http(context, opts).state != :available -> Provider.dependency("api.http")
      orchestration.state == :unavailable -> Provider.dependency("orchestration")
      Provider.writable(context) == false -> %{state: :unavailable, reason: :disabled}
      Provider.writable(context) == :unknown -> %{state: :unknown, reason: :unknown}
      true -> %{state: :available}
    end
  end
end
