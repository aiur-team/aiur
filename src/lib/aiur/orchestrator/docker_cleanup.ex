defmodule Aiur.Orchestrator.DockerCleanup do
  @moduledoc """
  Stops and removes containers owned by a terminal ticket.
  """

  require Logger

  @label "aiur.ticket"

  @spec start_ticket_cleanup(term()) :: :ok
  def start_ticket_cleanup(ticket) when is_binary(ticket) do
    cleanup = fn -> cleanup_ticket(ticket) end

    case Process.whereis(Aiur.TaskSupervisor) && Task.Supervisor.start_child(Aiur.TaskSupervisor, cleanup) do
      {:ok, _pid} -> :ok
      _ -> cleanup.()
    end
  end

  def start_ticket_cleanup(_ticket), do: :ok

  @spec cleanup_ticket(term(), keyword()) :: :ok
  def cleanup_ticket(ticket, opts \\ [])

  def cleanup_ticket(ticket, opts) when is_binary(ticket) do
    command = Keyword.get(opts, :command, &System.cmd/3)

    case command.("docker", ["ps", "-aq", "--filter", "label=#{@label}=#{ticket}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split(~r/\s+/, trim: true)
        |> Enum.each(&stop_and_remove(&1, ticket, command))

        :ok

      {output, status} ->
        Logger.warning("Could not list ticket Docker containers ticket=#{ticket} status=#{status} output=#{String.trim(output)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Could not clean ticket Docker containers ticket=#{ticket} error=#{Exception.message(error)}")
      :ok
  end

  def cleanup_ticket(_ticket, _opts), do: :ok

  defp stop_and_remove(container, ticket, command) do
    case command.("docker", ["rm", "-f", container], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> Logger.warning("Could not remove ticket Docker container ticket=#{ticket} container=#{container} status=#{status} output=#{String.trim(output)}")
    end
  end
end
