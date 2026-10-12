defmodule Aiur.BuildQueue.CapabilityProvider do
  @moduledoc "Read-only build queue contributions to the capability registry."
  @behaviour Aiur.Capabilities.Provider

  @unknown %{state: :unknown, reason: :unknown}

  @impl true
  def capability_ids, do: ["build_queue", "build_queue.build_order_source"]

  @impl true
  def capabilities(_context) do
    queue = queue_capability(Aiur.BuildQueue.status())
    %{"build_queue" => queue, "build_queue.build_order_source" => source_capability(queue)}
  rescue
    _error -> unknown()
  catch
    :exit, _reason -> unknown()
  end

  # A map lookup keeps the unknown fallback for an unrecognised status reply,
  # which dialyzer would reject as an unreachable case clause.
  @queue_states %{
    running: %{state: :available},
    disabled: %{state: :unavailable, reason: :disabled},
    unsupported_tracker: %{state: :unavailable, reason: :unsupported_tracker},
    store_unavailable: %{state: :unavailable, reason: :store_unavailable},
    writes_paused: %{state: :degraded, reason: :writes_paused}
  }

  defp queue_capability(status), do: Map.get(@queue_states, status, @unknown)

  defp source_capability(%{state: state}) when state in [:available, :degraded] do
    case Aiur.BuildQueue.show().build_queue.build_order_source do
      true -> %{state: :available}
      false -> %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_orders"]}
      _ -> @unknown
    end
  end

  defp source_capability(_queue), do: %{state: :unavailable, reason: :dependency_unavailable, depends_on: ["build_queue"]}

  defp unknown, do: Map.new(capability_ids(), &{&1, @unknown})
end
