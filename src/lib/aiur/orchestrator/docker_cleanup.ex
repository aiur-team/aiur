defmodule Aiur.Orchestrator.DockerCleanup do
  @moduledoc """
  Stops and removes containers owned by a terminal ticket.

  Agent-started containers carry `aiur.workspace=<issue workspace path>`. The
  path includes the workspace root and repo segment, so tickets with the same
  number in another repo or daemon never match.
  """

  require Logger

  alias Aiur.Workspace.Layout

  @label "aiur.workspace"
  @stop_grace_seconds 30
  # Docker gets the stop grace period plus slack before the call is abandoned.
  @command_timeout_ms (@stop_grace_seconds + 30) * 1000

  @spec start_ticket_cleanup(term()) :: :ok
  def start_ticket_cleanup(ticket) when is_binary(ticket) do
    cleanup = fn -> cleanup_ticket(ticket) end

    # Never run docker in the caller: it is the orchestrator.
    with true <- is_pid(Process.whereis(Aiur.TaskSupervisor)),
         {:ok, _pid} <- Task.Supervisor.start_child(Aiur.TaskSupervisor, cleanup) do
      :ok
    else
      _ ->
        {:ok, _pid} = Task.start(cleanup)
        :ok
    end
  end

  def start_ticket_cleanup(_ticket), do: :ok

  @spec cleanup_ticket(term(), keyword()) :: :ok
  def cleanup_ticket(ticket, opts \\ [])

  def cleanup_ticket(ticket, opts) when is_binary(ticket) do
    command = Keyword.get_lazy(opts, :command, fn -> Application.get_env(:aiur, :docker_cleanup_command, &System.cmd/3) end)
    timeout_ms = Keyword.get(opts, :timeout_ms, @command_timeout_ms)
    run = fn args -> run_bounded(command, args, timeout_ms) end

    with {:ok, workspace} <- workspace_path(ticket),
         {output, 0} <- run.(["ps", "-aq", "--filter", "label=#{@label}=#{workspace}"]) do
      output
      |> String.split(~r/\s+/, trim: true)
      |> Enum.each(&stop_and_remove(&1, ticket, run))
    else
      {:error, reason} -> Logger.warning("Could not resolve ticket workspace for Docker cleanup ticket=#{ticket} reason=#{inspect(reason)}")
      {output, status} -> Logger.warning("Could not list ticket Docker containers ticket=#{ticket} status=#{status} output=#{String.trim(output)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("Could not clean ticket Docker containers ticket=#{ticket} error=#{Exception.message(error)}")
      :ok
  end

  def cleanup_ticket(_ticket, _opts), do: :ok

  defp workspace_path(ticket), do: ticket |> Layout.safe_identifier() |> Layout.workspace_path_for_issue(nil)

  defp stop_and_remove(container, ticket, run) do
    with {_output, 0} <- gone_ok(run.(["stop", "-t", "#{@stop_grace_seconds}", container])),
         {_output, 0} <- gone_ok(run.(["rm", container])) do
      :ok
    else
      {output, status} -> Logger.warning("Could not stop ticket Docker container ticket=#{ticket} container=#{container} status=#{status} output=#{String.trim(output)}")
    end
  end

  # `docker run --rm` containers remove themselves once stopped, so a missing
  # container or a removal already in progress is the success path.
  defp gone_ok({output, status}) when is_binary(output) and status != 0 do
    if output =~ "No such container" or output =~ "already in progress", do: {output, 0}, else: {output, status}
  end

  defp gone_ok(result), do: result

  defp run_bounded(command, args, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          command.("docker", args, stderr_to_stdout: true)
        rescue
          error -> {Exception.message(error), :error}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {"timed out after #{timeout_ms}ms", :timeout}
    end
  end
end
