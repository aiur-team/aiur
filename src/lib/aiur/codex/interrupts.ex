defmodule Aiur.Codex.Interrupts do
  @moduledoc """
  Codex-specific interrupt error tolerance.
  """

  alias Aiur.AppServer.Interrupts
  alias Aiur.Codex.NotificationPolicy

  @spec handle_interrupt_error(map(), term()) ::
          {:ok, :turn_completed} | {:paused, map()} | {:continue, map()} | {:error, term()}
  def handle_interrupt_error(state, error) do
    if NotificationPolicy.no_active_turn_error?(error) do
      Interrupts.handle_no_active_turn_error(state, error)
    else
      {:error, {:turn_interrupt_failed, error}}
    end
  end
end
