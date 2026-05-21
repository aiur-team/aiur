defmodule Aiur.Opencode.PrewarmSupervisor do
  @moduledoc """
  Groups the boot-time pre-warm processes: `Aiur.Opencode.WarmServer`
  (the neutral-cwd `opencode serve`) and `Aiur.Opencode.WarmAttach`
  (the hidden tmux window holding `opencode attach`).

  The per-identifier writer machinery (`SessionWriterRegistry.Registry`
  + `SessionSupervisor`) sits at top-level in `Aiur.Application`, not
  under this supervisor — writers spawn even when pre-warm is disabled
  or hasn't reached `:ready_with_placeholder` yet.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        Aiur.Opencode.WarmServer,
        Aiur.Opencode.WarmAttach
      ],
      strategy: :one_for_one
    )
  end
end
