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

  alias Aiur.ControlCall.KeyedReceipt
  alias Aiur.Orchestrator.{PauseResume, TicketTransition}

  @spec rework(String.t(), String.t()) :: :ok
  def rework(issue, reason), do: rework(issue, reason, [])

  @doc false
  @spec rework(String.t(), String.t(), keyword()) :: :ok
  def rework(issue, reason, deps) when is_binary(issue) and is_binary(reason) and is_list(deps) do
    reason = String.trim(reason)

    guarded("rework", fn ->
      case Keyword.get(deps, :key) do
        key when is_binary(key) and key != "" -> keyed(issue, reason, key, deps)
        _unkeyed -> issue |> run(reason, deps) |> elem(0) |> exit_marker()
      end
    end)
  end

  # `--key` makes the whole sequence at-most-once for a caller that may crash
  # and retry: the first call keeps a durable receipt and a repeat returns it
  # without queueing the reason or requesting a turn again. A first call that
  # failed may run again; its reason carries the key as its message id, so the
  # queue still refuses a second copy.
  defp keyed(issue, reason, key, deps) do
    attempt = fn ->
      {code, request_id} = run(issue, reason, deps)
      %{"exit" => code, "request_id" => request_id}
    end

    case KeyedReceipt.run("rework", key, {issue, reason}, attempt) do
      {:new, %{"exit" => code}} ->
        exit_marker(code)

      {:replay, %{"exit" => 0, "request_id" => request_id}} ->
        IO.puts("aiur: rework #{key} already ran for #{issue} (reason request #{request_id}); nothing queued again")
        exit_marker(0)

      {:replay, _failed} ->
        exit_marker(attempt.()["exit"])

      {:error, reason} ->
        control_error("aiur: rework #{key} did not run: #{KeyedReceipt.describe(reason)}")
        exit_marker(KeyedReceipt.exit_code(reason))
    end
  end

  defp run(_issue, "", _deps) do
    control_error("aiur: rework requires a nonblank --reason")
    {64, nil}
  end

  defp run(issue, reason, deps) do
    id = Keyword.get(deps, :identifier, &resolve_identifier/1).(issue)
    Keyword.get(deps, :pin, &pin/1).(id)

    send_opts = if is_binary(deps[:key]), do: [message_id: "rework:" <> deps[:key]], else: []
    send = fn -> Keyword.get(deps, :send, &Aiur.AgentChat.send/3).(id, message(reason), send_opts) end
    write_state = fn -> Keyword.get(deps, :state, &TicketTransition.write_state/3).(id, "rework", writer: :executor_rework) end

    with {:send, {:ok, request}} <- {:send, send.()},
         {:state, :ok} <- {:state, write_state.()} do
      queued(issue, id, request, deps)
    else
      {:send, {:error, reason}} -> retry_after_label(issue, id, reason, send, write_state, deps)
      {:state, {:error, reason}} -> fail(issue, "could not write agent:rework (#{inspect(reason)})")
    end
  end

  # With no live worker the send starts one, and while the ticket still holds
  # its old state that start fails and nothing is queued (Open-Games #330).
  # Write rework first, then queue the reason again.
  defp retry_after_label(issue, id, reason, send, write_state, deps) when is_tuple(reason) and elem(reason, 0) in [:dispatch_failed, :redispatch_deferred] do
    with {:state, :ok} <- {:state, write_state.()},
         {:send, {:ok, request}} <- {:send, send.()} do
      queued(issue, id, request, deps)
    else
      {:state, {:error, state_reason}} -> fail(issue, "could not write agent:rework (#{inspect(state_reason)})")
      {:send, {:error, send_reason}} -> fail(issue, "agent:rework is written but the reason could not be queued (#{inspect(send_reason)})")
    end
  end

  defp retry_after_label(issue, _id, reason, _send, _write_state, _deps),
    do: fail(issue, "could not queue the reason (#{inspect(reason)})")

  defp queued(issue, id, request, deps) do
    IO.puts("aiur: ticket #{issue} is in agent:rework; its PR is unchanged and the reason is queued for the worker (request #{request_id(request)})")
    {report_turn(issue, Keyword.get(deps, :resume, &PauseResume.resume_agent/1).(id)), request_id(request)}
  end

  defp request_id(request) when is_integer(request), do: request
  defp request_id(%{item: %{id: id}}), do: id
  defp request_id(_request), do: nil

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
    {1, nil}
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
