defmodule Aiur.Orchestrator.OperatorMessages.CorrelatedReplayWakeTest do
  @moduledoc """
  #2558 half two: a decision answer that resolves to an already-enqueued
  correlated item must still wake a paused target.

  Delivering an answer to a paused agent normally resumes it, because the
  delivery is an operator message and `enqueue_for_running_entry/5` wakes a
  paused entry. But a *replayed* correlated message — the same action
  dispatched again after a store restart, a superseding schedule, or a
  duplicate answer — short-circuits on the existing queue item and never
  reaches that wake. The Decision is then recorded queued (a success) while
  the agent sits paused on an answer it will never see, with no failure
  anywhere for an operator to find. That is the observed ticket-40 stall: the
  agent re-raised the same pause minutes later, having never seen the answer.
  """

  use ExUnit.Case, async: false

  alias Aiur.{Issue, Orchestrator}
  alias Aiur.Orchestrator.OperatorMessages

  @identifier "981"

  test "a replayed decision answer resumes an agent that paused again" do
    {orchestrator, pid} = start_orchestrator!(Module.concat(__MODULE__, :Replay))

    payload = correlated_payload("a1")

    assert {:ok, %{status: :accepted, item: %{action_id: "act_replay_wake"}}} =
             OperatorMessages.send_correlated_operator_message(orchestrator, @identifier, payload)

    # The agent re-raises its Command and pauses again before consuming the
    # queued answer — exactly what the reported run observed.
    pause_agent!(pid)
    assert paused?(pid)

    # The same action is dispatched again. The durable queue item already
    # exists, so this is a duplicate: correct, and still undelivered work.
    assert {:ok, %{status: :duplicate, item: %{action_id: "act_replay_wake"}}} =
             OperatorMessages.send_correlated_operator_message(
               orchestrator,
               @identifier,
               correlated_payload("a2")
             )

    # Acceptance: the agent is able to make progress with no operator call.
    refute paused?(pid)
    assert control_status(pid) == :working
    assert Map.get(running_entry(pid), :paused_reason) == nil
  end

  test "the wake is idempotent and never fires for an unpaused agent" do
    {orchestrator, pid} = start_orchestrator!(Module.concat(__MODULE__, :Idempotent))

    assert {:ok, %{status: :accepted}} =
             OperatorMessages.send_correlated_operator_message(
               orchestrator,
               @identifier,
               correlated_payload("a1")
             )

    pause_agent!(pid)

    for attempt <- ["a2", "a3", "a4"] do
      assert {:ok, %{status: :duplicate}} =
               OperatorMessages.send_correlated_operator_message(
                 orchestrator,
                 @identifier,
                 correlated_payload(attempt)
               )

      # The first replay wakes the entry; every later one finds it already
      # working and is a no-op rather than a repeated resume, so a dispatch
      # that retries cannot storm the agent with control messages.
      assert control_status(pid) == :working
    end
  end

  defp correlated_payload(attempt_id) do
    %{
      kind: :text,
      body: "Custom response: Proceed",
      delivery_policy: :interrupt,
      fallback: :queue_next,
      action_id: "act_replay_wake",
      correlation: %{
        decision_id: "dec_replay_wake",
        action_id: "act_replay_wake",
        attempt_id: attempt_id
      },
      retry_failed: false
    }
  end

  defp start_orchestrator!(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)
    parent = self()
    worker_pid = spawn(fn -> worker_probe(parent) end)
    issue_id = "issue-#{@identifier}"

    :sys.replace_state(pid, fn state ->
      %{state | running: %{issue_id => running_entry(issue_id, worker_pid)}}
    end)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(pid)
      if Process.alive?(worker_pid), do: Process.exit(worker_pid, :normal)
    end)

    {name, pid}
  end

  defp running_entry(issue_id, worker_pid) do
    %{
      pid: worker_pid,
      ref: make_ref(),
      identifier: @identifier,
      issue: %Issue{id: issue_id, identifier: @identifier, state: "In Progress", title: "OCC-3"},
      control: %{can_interrupt: true, safe_checkpoints: [:notification], status: :working},
      session_id: "thread-#{@identifier}",
      agent_input_tokens: 0,
      agent_output_tokens: 0,
      agent_total_tokens: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp pause_agent!(pid) do
    :sys.replace_state(pid, fn state ->
      running =
        Map.new(state.running, fn {id, entry} ->
          {id,
           entry
           |> put_in([:control, :status], :paused)
           |> Map.put(:paused_reason, :agent_pause_request)}
        end)

      %{state | running: running}
    end)

    :ok
  end

  defp running_entry(pid) do
    pid |> :sys.get_state() |> Map.fetch!(:running) |> Map.values() |> List.first()
  end

  defp control_status(pid), do: pid |> running_entry() |> get_in([:control, :status])

  defp paused?(pid), do: control_status(pid) == :paused

  defp worker_probe(parent) do
    receive do
      message ->
        send(parent, {:worker_got, message})
        worker_probe(parent)
    end
  end
end
