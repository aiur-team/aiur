defmodule Aiur.Orchestrator.TicketTransition do
  @moduledoc """
  Owns ticket state and marker writes, with caller attribution and outcome evidence.

  The tracker label is authoritative: repeated writes retain adapter semantics.
  This owner never retries; callers reconcile labels before deciding again.
  Errors are returned unchanged. Transport/deadline failures have unknown outcomes.
  `tracker:` names the facade-shaped module to call (default `Aiur.Tracker`); the
  build queue passes its injected tracker so its writes are attributed here too.
  """

  require Logger
  alias Aiur.Tracker

  @spec write_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_state(issue_id, to_state, opts) do
    writer = Keyword.fetch!(opts, :writer)
    true = is_atom(writer) and not is_nil(writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    result = with_writer(writer, fn -> tracker.update_issue_state(issue_id, to_state, Keyword.drop(opts, [:writer, :identifier, :tracker])) end)
    record(issue_id, :state, to_state, writer, opts, result)
    result
  end

  @spec write_marker(String.t(), :add | :remove, String.t(), keyword()) :: :ok | {:error, term()}
  def write_marker(issue_id, action, label, opts) when action in [:add, :remove] do
    writer = Keyword.fetch!(opts, :writer)
    true = is_atom(writer) and not is_nil(writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    result = with_writer(writer, fn -> if action == :add, do: tracker.add_label(issue_id, label), else: tracker.remove_label(issue_id, label) end)
    record(issue_id, action, label, writer, opts, result)
    result
  end

  defp with_writer(writer, fun) do
    previous = Process.get(:aiur_ticket_writer)
    Process.put(:aiur_ticket_writer, writer)

    try do
      fun.()
    after
      if previous == nil, do: Process.delete(:aiur_ticket_writer), else: Process.put(:aiur_ticket_writer, previous)
    end
  end

  defp record(issue_id, action, to, writer, opts, result) do
    meta = %{issue_id: issue_id, identifier: opts[:identifier], action: action, to: to, expected: opts[:expected_state], writer: writer, outcome: outcome(result)}
    # ponytail: daemon/CLI logs are durable evidence; IssueLog needs a ticket observation before subscribing.
    Logger.info("ticket_transition issue_id=#{issue_id} action=#{action} to=#{inspect(to)} expected=#{inspect(meta.expected)} writer=#{writer} outcome=#{inspect(meta.outcome)}")
    :telemetry.execute([:aiur, :ticket_transition], %{}, meta)
  end

  defp outcome(:ok), do: :ok
  defp outcome({:error, {:github, kind, _}}) when kind in [:timeout, :transport, :dns, :tls], do: :unknown
  defp outcome({:error, reason}) when reason in [:timeout, :deadline_exceeded], do: :unknown
  defp outcome(result), do: result
end
