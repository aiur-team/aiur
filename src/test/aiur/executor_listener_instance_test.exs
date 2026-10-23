defmodule Aiur.ExecutorListenerInstanceTest do
  use Aiur.TestSupport

  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox

  @listener_name __MODULE__.Listener
  @inbox_name __MODULE__.Inbox

  defmodule RecordingAlertSink do
    @moduledoc false
    def emit_system(topic, opts), do: Aiur.Alerts.emit_system(topic, opts)

    def emit_custom("executor.command." <> _kind = topic, _message, _opts) do
      send(Aiur.ExecutorListenerInstanceTest, {:command_alert, topic})
      :ok
    end

    def emit_custom(topic, message, opts), do: Aiur.Alerts.emit_custom(topic, message, opts)
  end

  setup do
    signal = Application.get_env(:aiur, :signal)
    previous_alerts? = Application.get_env(:aiur, :executor_command_alerts?)
    Application.put_env(:aiur, :executor_command_alerts?, true)

    on_exit(fn ->
      Application.put_env(:aiur, :signal, signal)
      if is_nil(previous_alerts?), do: Application.delete_env(:aiur, :executor_command_alerts?), else: Application.put_env(:aiur, :executor_command_alerts?, previous_alerts?)
      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
    end)

    :ok
  end

  defp start_listener(opts) do
    start_supervised!({ExecutorListener, Keyword.merge([name: @listener_name, resubscribe_interval_ms: 100], opts)})
  end

  defp write_ignore(ticket) do
    path = Workflow.workflow_file_path()
    write_workflow_file_atomic!(path, File.read!(path) <> "\ninstance:\n  ignore:\n    tickets: [#{ticket}]\n")
    :ok = Aiur.WorkflowStore.force_reload()
  end

  test "another instance's ticket events are not projected into this Executor's inbox (#5803)" do
    [foreign, native] = for _ <- 1..2, do: System.unique_integer([:positive])
    write_ignore(foreign)
    start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})
    start_listener(inbox: @inbox_name, patterns: ["ticket.#{foreign}.pr.opened", "ticket.#{native}.pr.opened"], reconcile?: false)

    for ticket <- [foreign, native], topic = "ticket.#{ticket}.pr.opened" do
      Exchange.publish(topic, %{id: System.unique_integer([:positive]), topic: topic, action: "opened", pr: %{"number" => ticket, "draft" => false}})
    end

    assert {:ok, wakes} = ExecutorWakeInbox.wait(500, @inbox_name)
    assert Enum.map(wakes, & &1["ticket"]) == ["#{native}"]
  end

  test "foreign blocking Decisions do not alert or wake this Executor" do
    ticket = "3141"
    write_ignore(ticket)
    Process.register(self(), __MODULE__)
    signal = Application.get_env(:aiur, :signal)
    Application.put_env(:aiur, :signal, Keyword.put(signal, :alert_sink, RecordingAlertSink))
    start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})

    decision = %Decision{
      decision_id: "foreign-escalation",
      version: 1,
      ticket: %{identifier: ticket, title: "Executor events", url: nil},
      source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: true,
      reversibility: :reversible,
      question: "Should the Executor handle this?",
      context: %{short_summary: "A command for the Executor", long_context_markdown: nil},
      options: [],
      artifacts: [],
      created_at: DateTime.add(DateTime.utc_now(), -50 * 60, :second),
      content_hash: "content-hash"
    }

    test_pid = self()

    escalation = [
      decisions_fun: fn -> {:ok, [decision]} end,
      now: DateTime.utc_now(),
      gates_fun: fn _ticket -> 0 end,
      condition_states_fun: fn topics -> Map.new(topics, &{&1, :unknown}) end,
      wake_fun: fn record -> send(test_pid, {:escalation_wake, record}) end,
      alert_fun: fn topic, opts -> send(test_pid, {:escalation_alert, topic, opts}) end
    ]

    listener = start_listener(inbox: @inbox_name, patterns: ["executor.#"], reconcile?: false, escalation_interval_ms: :infinity, escalation: escalation)
    topic = "executor.decision.requested"

    Exchange.publish(topic, %{
      id: System.unique_integer([:positive]),
      topic: topic,
      issue_identifier: ticket,
      decision_id: "foreign-decision",
      blocking: true,
      title: "Foreign decision",
      recommendation: nil
    })

    assert is_map(:sys.get_state(listener))
    refute_receive {:command_alert, _topic}, 50
    assert :timeout = ExecutorWakeInbox.wait(50, @inbox_name)
    send(listener, :escalate)
    assert is_map(:sys.get_state(listener))
    refute_receive {:escalation_wake, _}, 50
    refute_receive {:escalation_alert, _, _}, 50
  end
end
