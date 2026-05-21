defmodule Aiur.Opencode.PrewarmSupervisor do
  @moduledoc """
  Groups the slot-bound pre-warm processes:

  - `Aiur.Opencode.HiddenWindow` — creates the hidden tmux window once
    at boot. Every slot's opencode-attach pane lives in here when not
    visible.
  - `Aiur.Opencode.SlotSupervisor` — `DynamicSupervisor` that spawns
    `Aiur.Opencode.Slot` workers per slot index.
  - `Aiur.Opencode.SlotPolicy` — chain pre-warm orchestrator; starts
    slot 1 at init, then slot N+1 once slot N broadcasts `:slot_ready`.

  The per-identifier writer machinery (`SessionWriterRegistry.Registry`
  + `SessionSupervisor`) sits at top-level in `Aiur.Application`, not
  under this supervisor — writers spawn even when pre-warm is disabled.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        Aiur.Opencode.HiddenWindow,
        Aiur.Opencode.SlotSupervisor,
        Aiur.Opencode.SlotPolicy
      ],
      strategy: :one_for_one
    )
  end
end
