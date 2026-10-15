defmodule Aiur.Orchestrator.AdoptedBoot do
  @moduledoc false

  alias Aiur.Config
  alias Aiur.Orchestrator.{EnvelopeResume, Slots, State}

  @spec restore(State.t()) :: State.t()
  def restore(state) do
    count = MapSet.size(adopted_ids(state))

    if count == 0 do
      state
    else
      target = Config.target_cpu_pressure() || Config.target_load_average()
      envelope = EnvelopeResume.validate(state.load_envelope_state, target, System.schedulers_online())
      saved = max(EnvelopeResume.level(envelope, target) || 1, state.effective_concurrent_agents || 1)
      effective = max(count, min(saved, Slots.max_concurrent_agent_limit(state)))
      %{state | effective_concurrent_agents: effective, load_envelope_state: Map.put(envelope, :bootstrap_complete?, true)}
    end
  end

  @spec candidate_cache(map(), State.t()) :: map()
  def candidate_cache(cache, %{poll_cycles_completed: 0} = state) do
    ids = adopted_ids(state)
    if MapSet.size(ids) > 0, do: Map.put(cache, :adopted_issue_ids, ids), else: Map.delete(cache, :adopted_issue_ids)
  end

  def candidate_cache(cache, _state), do: Map.delete(cache, :adopted_issue_ids)

  defp adopted_ids(state), do: state.running |> Enum.filter(fn {_id, entry} -> is_binary(entry[:adopted_from]) end) |> MapSet.new(&elem(&1, 0))
end
