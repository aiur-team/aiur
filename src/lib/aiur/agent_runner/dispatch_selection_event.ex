defmodule Aiur.AgentRunner.DispatchSelectionEvent do
  @moduledoc """
  Writes the headroom dispatch decision (#3960) to the ticket's agent event
  stream (`logs/agent.ndjson` and `agent.md`), so the workspace records which
  backend and account were chosen and the score of every alternative.

  Writes nothing when the issue carries no `dispatch_selection`, which is the
  case under every policy other than `account_selection: headroom`.
  """

  alias Aiur.{AgentEventLog, Issue}

  @spec write(Path.t() | nil, String.t() | nil, Issue.t()) :: :ok
  def write(workspace, worker_host, %Issue{dispatch_selection: %{summary: summary} = selection}) when is_binary(summary) do
    AgentEventLog.write(workspace, worker_host, event(selection))
  end

  def write(_workspace, _worker_host, _issue), do: :ok

  @doc "The event record for one selection."
  @spec event(map()) :: map()
  def event(selection) do
    %{
      event: :dispatch_selection,
      timestamp: DateTime.utc_now(),
      last_message: selection.summary,
      policy: selection[:policy],
      pinned: selection[:pinned],
      backend: selection[:backend],
      account: selection[:account],
      route: selection[:route],
      candidates: selection[:candidates] || []
    }
  end
end
