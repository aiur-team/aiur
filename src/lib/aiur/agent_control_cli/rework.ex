defmodule Aiur.AgentControlCLI.Rework do
  @moduledoc """
  `aiur rework <n> --reason <text>`: send a ticket back to `agent:rework`
  without touching its pull request.

  Relabelling by hand raced the worker's in-flight turn: its review handoff
  and the CI lifecycle moved the ticket to `ci-wait`, where `aiur resume` is
  refused (Open-Games #327). This command pins rework on the running entry,
  queues the reason (its fence then holds rework until the worker has it),
  writes the label, and asks for a worker turn.
  """

  import Aiur.ControlCLI.Protocol
  import Aiur.Orchestrator.ControlCLI, only: [control_status_snapshot: 0]
  import Aiur.Orchestrator.ControlCLI.Output, only: [canonical_identifier: 1, target_matches?: 2]

  alias Aiur.Orchestrator.{PauseResume, TicketTransition}

  @spec rework(String.t(), String.t()) :: :ok
  def rework(issue, reason), do: rework(issue, reason, [])

  @doc false
  @spec rework(String.t(), String.t(), keyword()) :: :ok
  def rework(issue, reason, deps) when is_binary(issue) and is_binary(reason) and is_list(deps) do
    guarded("rework", fn -> issue |> run(String.trim(reason), deps) |> exit_marker() end)
  end

  defp run(_issue, "", _deps) do
    control_error("aiur: rework requires a nonblank --reason")
    64
  end

  defp run(issue, reason, deps) do
    id = Keyword.get(deps, :identifier, &resolve_identifier/1).(issue)
    Keyword.get(deps, :pin, &pin/1).(id)

    with {:send, {:ok, _request}} <- {:send, Keyword.get(deps, :send, &Aiur.AgentChat.send/3).(id, message(reason), [])},
         {:state, :ok} <- {:state, Keyword.get(deps, :state, &TicketTransition.write_state/3).(id, "rework", writer: :executor_rework)} do
      IO.puts("aiur: ticket #{issue} is in agent:rework; its PR is unchanged and the reason is queued for the worker")
      report_turn(issue, Keyword.get(deps, :resume, &PauseResume.resume_agent/1).(id))
    else
      {:send, {:error, reason}} -> fail(issue, "could not queue the reason (#{inspect(reason)})")
      {:state, {:error, reason}} -> fail(issue, "could not write agent:rework (#{inspect(reason)})")
    end
  end

  defp message(reason) do
    "The Executor moved this ticket back to agent:rework. The PR stays as it is, so do not change its draft or ready state. " <>
      "Address this, push, then hand the ticket back:\n\n" <> reason
  end

  defp report_turn(issue, {:ok, :already_running}) do
    IO.puts("aiur: worker for #{issue} is running; it reads the reason at its next checkpoint")
    0
  end

  defp report_turn(issue, {:ok, _resumed}) do
    IO.puts("aiur: resumed worker for #{issue}")
    0
  end

  defp report_turn(issue, {:error, reason}) do
    control_error("aiur: no worker turn started for #{issue} (#{inspect(reason)}); the rework label and reason are recorded")
    1
  end

  defp fail(issue, detail) do
    control_error("aiur: rework failed for #{issue}: #{detail}")
    1
  end

  defp resolve_identifier(issue) do
    case control_status_snapshot() do
      statuses when is_list(statuses) ->
        case Enum.find(statuses, &target_matches?(&1, issue)) do
          nil -> issue
          status -> canonical_identifier(status)
        end

      _unavailable ->
        issue
    end
  end

  defp pin(identifier) do
    server = Aiur.Project.whereis(Aiur.Orchestrator)
    if GenServer.whereis(server), do: GenServer.call(server, {:pin_rework, identifier}, 10_000), else: {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
