defmodule Aiur.Opencode.PrewarmSupervisor do
  @moduledoc """
  Groups the boot-time pre-warm processes:
  - `Aiur.Opencode.WarmServer` — neutral-cwd `opencode serve` instance
  - `Aiur.Opencode.HiddenWindow` — owns the hidden tmux window where
    every background `opencode attach` pane lives
  - `Aiur.Opencode.AttachQueue` — enumerates agents and runs
    `AgentAttach` per identifier into the hidden window

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
        Aiur.Opencode.WarmServer,
        Aiur.Opencode.HiddenWindow,
        Aiur.Opencode.AttachQueue
      ],
      strategy: :one_for_one
    )
  end
end
