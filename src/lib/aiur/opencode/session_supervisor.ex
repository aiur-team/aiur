defmodule Aiur.Opencode.SessionSupervisor do
  @moduledoc """
  Top-level `DynamicSupervisor` for per-identifier `Aiur.Opencode.SessionWriter`
  processes. Lives alongside `Aiur.IssueLog.Supervisor` in `Aiur.Application`'s
  main children list (not in `cli_children`) so writers run for every agent
  whether or not the interactive tmux UI is up.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
