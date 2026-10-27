defmodule Aiur.Workspace.Ownership.Guardian.Receipt do
  @moduledoc false

  alias Aiur.Workspace.Ownership.Store

  @spec persist_update(map(), map()) :: tuple()
  def persist_update(_previous, next) do
    case persist_state(next) do
      :ok -> {:ok, next}
      {:error, _reason} -> {{:error, :workspace_ownership_lost}, next}
    end
  end

  @spec update_phase(map(), atom()) :: map()
  def update_phase(state, phase) do
    case Registry.update_value(state.registry, state.lease.ticket, &Map.put(&1, :phase, phase)) do
      {%{} = lease, _previous} ->
        next = %{state | lease: lease}
        _ = persist_state(next)

        if phase == :reaping and state.lease.phase != :reaping do
          emit_telemetry(next, :point, :reaping)
        end

        next

      _ ->
        state
    end
  end

  @spec persist_state(map()) :: :ok | {:error, term()}
  def persist_state(state), do: Store.put(state.lease.ticket, receipt(state), state.store)

  defp receipt(state) do
    %{
      "retained_since" => state.lease[:retained_since],
      "retained_cause" => state.lease[:retained_cause],
      ticket: state.lease.ticket,
      generation: state.lease.generation,
      owner_id: state.lease.owner_id,
      phase: state.lease.phase,
      provider_expected?: state.provider_expected?,
      provider: state.provider,
      provider_cleanup: state.provider_cleanup,
      provider_scope: state.provider_scope,
      provider_boot_id: state.provider_boot_id,
      host_lock: state.host_lock
    }
  end

  @spec emit_telemetry(map(), atom(), atom()) :: term()
  def emit_telemetry(state, boundary, outcome) do
    state.telemetry_fun.(state.lease, boundary, outcome)
  rescue
    _ -> :ok
  end
end
