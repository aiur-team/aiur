defmodule Aiur.IssueLog.CommandRecorder do
  @moduledoc false

  alias Aiur.{IssueLog, TrackerIdentity}
  alias Aiur.IssueLog.Writers

  @spec record_command(TrackerIdentity.t(), String.t(), keyword()) :: :ok
  def record_command(%TrackerIdentity{} = identity, command, opts) when is_binary(command) do
    command = String.slice(command, 0, 2_000)
    identifier = identity.identifier
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    event = %{
      id: Keyword.get(opts, :id, Aiur.Events.next_id()),
      topic: "ticket.#{identifier}.agent.command",
      message: command,
      observed_at: observed_at,
      timestamp: observed_at,
      ticket_observation: nil
    }

    :ok = IssueLog.attach(identity)

    case Writers.writer_for_path(identifier, IssueLog.log_path(identity), Writers.writer_key(identity)) do
      [{pid, _}] -> send(pid, {:aiur_event, :command, event})
      [] -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end
end
