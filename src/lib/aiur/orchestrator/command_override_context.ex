defmodule Aiur.Orchestrator.CommandOverrideContext do
  @moduledoc "Reads worker ownership and slot observations without consulting Commands."

  alias Aiur.Orchestrator.{Slots, State}

  @spec read(State.t(), String.t() | nil) :: %{worker: atom(), capacity: atom()}
  def read(%State{} = state, identifier) do
    entry = State.find_running_by_identifier(state.running, identifier)

    %{
      worker: worker_state(entry),
      capacity: if(Slots.available_slots(state) > 0, do: :available, else: :full)
    }
  end

  defp worker_state(nil), do: :unknown
  defp worker_state(%{control: %{status: :unrecoverable}}), do: :unrecoverable

  defp worker_state(entry) do
    if State.active_running_entry?(entry) and not State.sleeping_running_entry?(entry),
      do: :active,
      else: :resumable
  end
end
