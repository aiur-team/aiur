defmodule Aiur.Orchestrator.StatusReport.UsagePauseBackends do
  @moduledoc false
  # Names each `agent.priority` backend's availability on a usage-limit pause row (#7879).

  alias Aiur.Config
  alias Aiur.ModelAvailability
  alias Aiur.Orchestrator.StatusReason

  # Read once per status build, and only while a claim is paused on a provider limit.
  @spec for_running(map()) :: [{String.t(), :available | :limited}]
  def for_running(running) do
    if Enum.any?(running, fn {_id, entry} -> Map.get(entry, :paused_reason) == :usage_limit_exhausted end) do
      ledger = ModelAvailability.load()
      Enum.map(Config.agent_priority_backends(), &{&1, if(ModelAvailability.available?(&1, state: ledger), do: :available, else: :limited)})
    else
      []
    end
  rescue
    _error -> []
  end

  @spec pause_reason(term(), [{String.t(), :available | :limited}]) :: StatusReason.t() | nil
  def pause_reason(:usage_limit_exhausted, [_ | _] = backends), do: {:paused, :usage_limit_exhausted, {:backends, backends}}
  def pause_reason(reason, _backends), do: StatusReason.for_pause(reason)
end
