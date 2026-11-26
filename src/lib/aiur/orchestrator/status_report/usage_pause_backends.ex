defmodule Aiur.Orchestrator.StatusReport.UsagePauseBackends do
  @moduledoc false
  # Names each `agent.priority` backend's availability on a usage-limit pause row
  # (#7879), and why the capacity policy holds an otherwise available one (#7891).

  alias Aiur.CodingAgent.{CapacityGate, HeadroomDispatch, UsageFloorGate}
  alias Aiur.Config
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.StatusReason

  @type backend_state :: :available | :limited | {:held, atom()}

  # Read once per status build, and only while a claim is paused on a provider limit.
  @spec for_running(map(), keyword()) :: [{String.t(), backend_state()}]
  def for_running(running, opts \\ []) do
    if Enum.any?(running, fn {_id, entry} -> Map.get(entry, :paused_reason) == :usage_limit_exhausted end) do
      opts = Keyword.put_new_lazy(opts, :state, &ModelAvailability.load/0)
      backends = Keyword.get_lazy(opts, :priority_backends, &Config.agent_priority_backends/0)
      candidates = UsageFloorGate.candidates(backends, opts)
      %{entries: entries} = CapacityGate.evaluate(candidates, HeadroomDispatch.readings(candidates, opts), opts)
      Enum.map(backends, &{&1, backend_state(&1, entries, opts)})
    else
      []
    end
  rescue
    _error -> []
  end

  defp backend_state(backend, entries, opts) do
    mine = Enum.filter(entries, &(&1.candidate.backend == backend))

    cond do
      not ModelAvailability.available?(backend, opts) -> :limited
      Enum.any?(mine, &(&1.verdict == :allow and &1.reason != :limited)) -> :available
      held = Enum.find(mine, &(&1.verdict != :allow)) -> {:held, held.reason}
      true -> :limited
    end
  end

  @spec pause_reason(term(), [{String.t(), backend_state()}]) :: StatusReason.t() | nil
  def pause_reason(:usage_limit_exhausted, [_ | _] = backends), do: {:paused, :usage_limit_exhausted, {:backends, backends}}
  def pause_reason(reason, _backends), do: StatusReason.for_pause(reason)
end
