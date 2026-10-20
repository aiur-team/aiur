defmodule Aiur.Orchestrator.TicketTransition do
  @moduledoc """
  Owns ticket state and marker writes, with caller attribution and outcome evidence.

  The tracker label is authoritative: repeated writes retain adapter semantics.
  GitHub state writes retry local budget holds at the request boundary.
  Errors are returned unchanged. Transport/deadline failures have unknown outcomes.
  `tracker:` names the facade-shaped module to call (default `Aiur.Tracker`); the
  build queue passes its injected tracker so its writes are attributed here too.
  """

  require Logger
  alias Aiur.Orchestrator.{AgentTeardown, CiLifecycle, Effect, HumanReview, PauseResume, RetryEngine, State}
  alias Aiur.Tracker

  @doc "Apply requests in order, before the caller reads transition output."
  @spec apply_effects(State.t(), [Effect.t()]) :: State.t()
  def apply_effects(state, effects) do
    Enum.reduce(effects, state, fn effect, current ->
      case apply_effect(current, effect) do
        {_result, %State{} = next} -> next
        %State{} = next -> next
      end
    end)
  end

  @doc "Apply one effect, preserving resume/reactivate outcomes for dependent actions."
  @spec apply_effect(State.t(), Effect.t()) :: State.t() | {term(), State.t()}
  def apply_effect(state, {:terminate, id, cleanup?}), do: AgentTeardown.terminate_running_issue(state, id, cleanup?)
  def apply_effect(state, {:resume_paused, entry, operator?}), do: PauseResume.resume_paused_issue(state, entry, operator?)
  def apply_effect(state, {:reactivate, entry}), do: PauseResume.reactivate_issue(state, entry)
  def apply_effect(state, {:transition_control, entry, status, reason}), do: PauseResume.transition_control_status(state, entry, status, reason)
  def apply_effect(state, {:preserve_on_external_error, issue}), do: RetryEngine.preserve_running_issue_on_external_error(state, issue)
  def apply_effect(state, {:pause_for_ci_wait, issue}), do: CiLifecycle.pause_issue_for_ci_wait(state, issue)
  def apply_effect(state, {:maybe_deactivate_human_review, issue}), do: HumanReview.maybe_deactivate_human_review_issue(state, issue)

  @spec write_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_state(issue_id, to_state, opts) do
    writer = Keyword.fetch!(opts, :writer)
    true = is_atom(writer) and not is_nil(writer)
    tracker = Keyword.get(opts, :tracker, Tracker)

    adapter_opts = Keyword.drop(opts, [:writer, :identifier, :tracker])
    result = with_writer(writer, fn -> tracker.update_issue_state(issue_id, to_state, adapter_opts) end)

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

  @spec write_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_comment(issue_id, body, opts) do
    writer = Keyword.fetch!(opts, :writer)
    tracker = Keyword.get(opts, :tracker, Tracker)
    result = with_writer(writer, fn -> tracker.create_comment(issue_id, body) end)
    record(issue_id, :comment, body, writer, opts, result)
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
