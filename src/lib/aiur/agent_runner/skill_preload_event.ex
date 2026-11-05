defmodule Aiur.AgentRunner.SkillPreloadEvent do
  @moduledoc """
  Writes the skill preload decision to the ticket's agent event stream
  (`logs/agent.ndjson` and `agent.md`), so the workspace records which skills a
  worker got, why each one was selected, and which mapped names were missing or
  over the inline byte budget.

  This is the durable half of the visibility requirement: `aiur agents` shows a
  compact form for a live worker, and this record answers the same question
  after the run is over. Writes nothing for a remote worker host, matching
  `DispatchSelectionEvent`, because the log lives in the local workspace.
  """

  alias Aiur.AgentEventLog
  alias Aiur.AgentSkills.Preload

  @spec write(Path.t() | nil, String.t() | nil, Preload.t() | nil) :: :ok
  def write(workspace, worker_host, %Preload{} = preload) when is_binary(workspace) do
    AgentEventLog.write(workspace, worker_host, Preload.dispatch_record(preload))
  end

  def write(_workspace, _worker_host, _preload), do: :ok
end
