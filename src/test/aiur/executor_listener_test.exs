defmodule Aiur.ExecutorListenerTest do
  use Aiur.TestSupport

  import ExUnit.CaptureLog

  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.Executor.StatePaths
  alias Aiur.ExecutorBindings
  alias Aiur.ExecutorEvents
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox
  alias Aiur.JsonStore

  @listener_name Aiur.ExecutorListener.Test
  @inbox_name Aiur.ExecutorWakeInbox.ListenerTest

  # Holds the listener inside each Command alert until the test releases it, so
  # a test controls how long delivery takes instead of racing it (#4633).
  defmodule GatedAlertSink do
    @moduledoc false
    def emit_system(topic, opts), do: Aiur.Alerts.emit_system(topic, opts)

    # A released alert skips the real alert I/O: the test asserts wakes, not alerts.
    def emit_custom("executor.command." <> _kind = topic, _message, _opts) do
      send(Aiur.ExecutorListenerTest, {:alert_gate, self(), topic})

      receive do
        :release -> :ok
      after
        10_000 -> raise "GatedAlertSink was never released for #{topic}"
      end
    end

    def emit_custom(topic, message, opts), do: Aiur.Alerts.emit_custom(topic, message, opts)
  end

  setup do
    # The listener reads/writes its durable watermark under the per-test log
    # root (TestSupport isolates :log_file), so a "restart" in a test starts a
    # fresh process over the same watermark.
    previous_health_alert_fun = Application.get_env(:aiur, :executor_listener_health_alert_fun)

    # Command alerts are now bound to an Executor-owned run: recording is
    # unconditional, but asking a human to answer something is not (#2099).
    Application.put_env(:aiur, :executor_command_alerts?, true)

    on_exit(fn ->
      Application.delete_env(:aiur, :executor_command_alerts?)

      if previous_health_alert_fun do
        Application.put_env(:aiur, :executor_listener_health_alert_fun, previous_health_alert_fun)
      else
        Application.delete_env(:aiur, :executor_listener_health_alert_fun)
      end

      for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      :ok
    end)

    :ok
  end

  defp start_listener(opts \\ []) do
    start_supervised!({ExecutorListener, Keyword.merge([name: @listener_name, resubscribe_interval_ms: 100], opts)})
  end

  defp command_decision(decision_id) do
    %Decision{
      decision_id: decision_id,
      version: 1,
      ticket: %{identifier: "1380", title: "Executor events", url: nil},
      source: %{agent_id: "agent-1", session_id: "session-1", event_id: nil},
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Should the Executor handle this?",
      context: %{short_summary: "A command for the Executor", long_context_markdown: nil},
      options: [%{id: "yes", label: "Yes", description: nil, benefits: nil, drawbacks: nil, risk: nil}],
      artifacts: [],
      created_at: DateTime.utc_now(),
      content_hash: "content-hash"
    }
  end

  defp watermark_path, do: StatePaths.watermark_path()

  defp watermark do
    case JsonStore.read(watermark_path()) do
      {:ok, %{"last_seen_event_id" => id}} when is_integer(id) -> id
      _other -> nil
    end
  end

  test "subscribes to executor.# on launch and reports alive only while listening" do
    pid = start_listener()

    assert is_pid(pid)
    assert "executor.#" in Exchange.bindings_for(pid)
    assert ExecutorListener.alive?(@listener_name)
  end

  test "re-subscribe checks never duplicate the binding" do
    pid = start_listener(resubscribe_interval_ms: :infinity)

    # Drive each scheduler tick explicitly. The Exchange binding table is a
    # duplicate bag, so an unconditional re-subscribe would multiply delivery.
    # Reading the state after each send doubles as a mailbox barrier, which is
    # why this needs no sleep to be reliable (#2039).
    for _tick <- 1..3 do
      send(pid, :resubscribe)
      assert :sys.get_state(pid).health == :present
      assert Enum.sort(Exchange.bindings_for(pid)) == Enum.sort(ExecutorBindings.patterns())
    end

    assert ExecutorListener.alive?(@listener_name)
  end

  test "re-subscribes and replays missed events after the Exchange drops the binding" do
    :ok = Exchange.subscribe("executor.command.requested")
    pid = start_listener(resubscribe_interval_ms: :infinity)

    first = command_decision("dec-gap-first")
    assert {:ok, first_id, 1} = ExecutorEvents.publish_requested(first)
    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => first_message}}, 1000
    assert first_message =~ "dec-gap-first"
    assert :sys.get_state(pid).watermark >= first_id
    assert watermark() >= first_id

    # Simulate the Exchange being restarted by the supervisor: its fresh
    # binding table no longer has this listener's row. The Command below is
    # synchronously proven to have no live subscriber during that real gap.
    table = :persistent_term.get({{Aiur.Events.Exchange, :table}, Aiur.Events.Exchange})
    :ets.match_delete(table, {:_, pid, :_})
    assert ExecutorListener.alive?(@listener_name) == false

    second = command_decision("dec-gap-second")
    assert {:ok, second_id, 0} = ExecutorEvents.publish_requested(second)
    refute_received {:event, %{"topic" => "executor.command.requested"}}

    # Drive the next re-subscribe tick and use the state read as a mailbox
    # barrier. It replays the missed Command and advances both watermarks, but
    # never re-notifies the already-delivered one.
    send(pid, :resubscribe)
    state = :sys.get_state(pid)

    assert state.health == :present
    assert state.watermark >= second_id
    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => replayed}}, 1000
    assert replayed =~ "dec-gap-second"
    refute_received {:event, %{"topic" => "executor.command.requested"}}
    assert watermark() >= second_id
  end

  test "reports not alive when no listener is running" do
    refute ExecutorListener.alive?(Aiur.ExecutorListener.NoSuch)
    refute ExecutorListener.alive?(@listener_name)
  end

  test "emits a needs-attention alert for a requested Command and advances its durable watermark" do
    :ok = Exchange.subscribe("executor.command.requested")
    start_listener()

    decision = command_decision("dec-listener-requested")
    assert {:ok, id, _count} = ExecutorEvents.publish_requested(decision)

    assert_receive {:event,
                    %{
                      "topic" => "executor.command.requested",
                      "source_ticket_id" => "1380",
                      "needs_attention" => true,
                      "message" => message
                    }},
                   500

    assert message =~ "dec-listener-requested"
    assert message =~ "ticket #1380"

    # The listener consumes the Command AND the alert it emitted for it, so the
    # durable watermark lands at or past the Command's journal id (shared id
    # counter). Wait for the write rather than racing the listener's mailbox.
    assert eventually(fn -> is_integer(watermark()) and watermark() >= id end)
  end

  test "emits a needs-attention alert for a deferred Command too" do
    :ok = Exchange.subscribe("executor.command.deferred")
    start_listener()

    assert {:ok, _id, _count} = ExecutorEvents.publish_deferred(command_decision("dec-listener-deferred"))

    assert_receive {:event, %{"topic" => "executor.command.deferred", "source_ticket_id" => "1380"}}, 500
  end

  test "does not alert for non-command executor events" do
    :ok = Exchange.subscribe("executor.command.requested")
    start_listener()

    assert {:ok, _id, _count} = ExecutorEvents.publish("executor.notify.release", %{message: "ready"})
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200
    refute_receive {:event, %{"topic" => "executor.command.deferred"}}, 100
  end

  test "daemon replay skips commands journaled before its binding floor" do
    :ok = Exchange.subscribe("executor.command.requested")

    assert {:ok, before_binding_id, _count} =
             ExecutorEvents.publish_requested(command_decision("dec-before-binding"))

    start_listener()

    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200
    assert watermark() == nil

    assert {:ok, after_binding_id, _count} =
             ExecutorEvents.publish_requested(command_decision("dec-after-binding"))

    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => message}}, 500
    assert message =~ "dec-after-binding"
    assert eventually(fn -> is_integer(watermark()) and watermark() >= after_binding_id end)
    assert before_binding_id < after_binding_id
  end

  test "non-executor events become wakes without advancing the command watermark" do
    start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})
    id = System.unique_integer([:positive])
    ticket = Integer.to_string(System.unique_integer([:positive]))
    topic = "ticket.#{ticket}.pr.opened"
    start_listener(inbox: @inbox_name, patterns: [topic], reconcile?: false)

    Exchange.publish(topic, %{
      id: id,
      topic: topic,
      action: "opened",
      pr: %{"number" => 2030, "draft" => false, "head" => %{"sha" => String.duplicate("a", 40)}}
    })

    assert {:ok, wakes} = ExecutorWakeInbox.wait(500, @inbox_name)
    assert Enum.any?(wakes, &(&1["ticket"] == ticket and &1["pr_number"] == 2030))
    assert watermark() == nil
  end

  test "system dispatch transitions become identifier-only wakes" do
    start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})
    start_listener(inbox: @inbox_name, patterns: ["system.dispatch.capacity_starved"], reconcile?: false)

    Exchange.publish("system.dispatch.capacity_starved", %{
      id: System.unique_integer([:positive]),
      topic: "system.dispatch.capacity_starved",
      message: "untrusted dispatch detail",
      needs_attention: true
    })

    assert {:ok,
            [
              %{
                "topic" => "system.dispatch.capacity_starved",
                "topic_class" => "system.dispatch.capacity_starved",
                "ticket" => nil,
                "needs_attention" => true
              }
            ]} = ExecutorWakeInbox.wait(500, @inbox_name)

    assert watermark() == nil
  end

  test "reports a degraded binding transition once and resolves it after repair" do
    parent = self()

    Application.put_env(:aiur, :executor_listener_health_alert_fun, fn name, message, opts ->
      send(parent, {:health_alert, name, message, opts})
      :ok
    end)

    patterns = ["executor.#", "ticket.*.pr.opened"]
    pid = start_listener(patterns: patterns, reconcile?: false, resubscribe_interval_ms: 60_000)
    refute_receive {:health_alert, _, _, _}, 50

    table = :persistent_term.get({{Aiur.Events.Exchange, :table}, Aiur.Events.Exchange})
    :ets.match_delete(table, {"ticket.*.pr.opened", pid, :_})
    assert ExecutorListener.bindings(@listener_name) == ["executor.#"]

    send(pid, :resubscribe)

    assert_receive {:health_alert, "executor.bindings.incomplete", message, opts}, 500
    assert message =~ "ticket.*.pr.opened"
    assert opts[:needs_attention] == true
    assert_receive {:health_alert, "executor.bindings.incomplete.resolved", _, resolved_opts}, 500
    assert resolved_opts[:needs_attention] == false
    refute_receive {:health_alert, _, _, _}, 100

    ExecutorListener.bindings(@listener_name)
    ExecutorListener.missing_defaults(@listener_name)
    refute_receive {:health_alert, _, _, _}, 50

    Application.put_env(:aiur, :executor_listener_health_alert_fun, fn _, _, _ -> raise "alert failed" end)
    :ets.match_delete(table, {"ticket.*.pr.opened", pid, :_})
    send(pid, :resubscribe)
    assert eventually(fn -> Enum.sort(Exchange.bindings_for(pid)) == Enum.sort(patterns) end)
    assert Process.alive?(pid)
  end

  test "a restarted listener replays only events newer than its durable watermark" do
    :ok = Exchange.subscribe("executor.command.requested")
    start_listener()

    first = command_decision("dec-restart-first")
    assert {:ok, first_id, _count} = ExecutorEvents.publish_requested(first)
    assert_receive {:event, %{"topic" => "executor.command.requested", "source_ticket_id" => "1380", "message" => first_message}}, 500
    assert first_message =~ "dec-restart-first"

    # Persisted watermark reflects the delivered event.
    assert eventually(fn -> is_integer(watermark()) and watermark() >= first_id end)

    # The listener dies (simulating a mid-run exit); a new Command is published
    # while nothing is listening.
    stop_supervised!(ExecutorListener)
    second = command_decision("dec-restart-second")
    assert {:ok, second_id, _count} = ExecutorEvents.publish_requested(second)
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200

    # A fresh listener over the same watermark replays the missed event but
    # never re-notifies for the already-delivered one.
    start_listener()

    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => replayed_message}}, 500
    assert replayed_message =~ "dec-restart-second"
    refute_receive {:event, %{"topic" => "executor.command.requested"}}, 200
    assert eventually(fn -> is_integer(watermark()) and watermark() >= second_id end)
  end

  # #4567: dec_2043ed93d73bbe63 on #3141 came from a codex agent through
  # DecisionStore.request, which journals only `executor.decision.requested`.
  # That path wrote no wake, so the Executor never heard of the Decision.
  test "a blocking Decision requested through DecisionStore wakes the Executor exactly once" do
    :ok = Aiur.TestSupport.ensure_id_generator_running()
    dir = Aiur.TestSupport.tmp_root!("aiur-decision-wake")

    Process.register(self(), __MODULE__)
    signal = Application.get_env(:aiur, :signal)
    on_exit(fn -> Application.put_env(:aiur, :signal, signal) end)
    Application.put_env(:aiur, :signal, Keyword.put(signal, :alert_sink, GatedAlertSink))

    suffix = System.unique_integer([:positive])
    ticket_identifier = "listener-wake-#{suffix}"

    start_supervised!({ExecutorWakeInbox, name: @inbox_name, debounce_ms: 10})

    listener =
      start_listener(
        inbox: @inbox_name,
        patterns: ["executor.#"],
        reconcile?: false,
        resubscribe_interval_ms: :infinity,
        escalation_interval_ms: :infinity
      )

    store =
      start_supervised!({Aiur.DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, executor_request_publisher: &Aiur.ExecutorEvents.publish_requested/1})

    context = [ticket: %{identifier: ticket_identifier, title: "Renderer", url: nil}, source: %{agent_id: "codex", session_id: "s-1", event_id: nil}]

    request = fn source_id, blocking ->
      payload = %{"question" => "Defer composed mobile pixels?", "blocking" => blocking, "authority" => "human_required", "source_id" => source_id}
      assert {:ok, %{status: :accepted, decision: decision}} = Aiur.DecisionStoreCase.request(store, payload, context)
      decision
    end

    _nonblocking = request.("parity-note-#{suffix}", false)
    decision = request.("parity-#{suffix}", true)

    # Both events are already in the listener's mailbox: the request publishes
    # them before it returns. The listener raises a Command alert for each one
    # before it reaches the blocking Decision's wake, so a wall-clock wait here
    # races that alert work. Under CI load the alerts outlasted the wait (#4633).
    assert_receive {:alert_gate, gate, "executor.command.requested"}, 5_000
    assert :timeout = ExecutorWakeInbox.wait(0, @inbox_name)
    send(gate, :release)
    assert_receive {:alert_gate, gate, "executor.command.requested"}, 5_000
    send(gate, :release)

    # Once this barrier returns, the listener has consumed both events and
    # enqueued every wake they produce; the wait only covers the inbox flush.
    assert "executor.#" in Exchange.bindings_for(listener)
    assert is_map(:sys.get_state(listener))
    assert {:ok, [wake]} = ExecutorWakeInbox.wait(1_000, @inbox_name)
    wake_topic = "ticket.#{ticket_identifier}.agent.attention.operator-decision"

    assert %{
             "topic" => ^wake_topic,
             "ticket" => ^ticket_identifier,
             "needs_attention" => true,
             "escalation" => "created",
             "question" => "Defer composed mobile pixels?",
             "count" => 1
           } = wake

    assert wake["decision_id"] == decision.decision_id
    assert [_only] = ExecutorWakeInbox.pending(@inbox_name)
  end

  # #4575 review: a ladder fault must not crash the process that holds the Executor bindings.
  describe "decision escalation faults" do
    test "a raising decision store leaves the listener alive and bound" do
      assert_survives(decisions_fun: fn -> raise "decision store exploded" end)
    end

    test "an exiting gate count leaves the listener alive and bound" do
      {:ok, decision} =
        Aiur.DecisionValidation.normalize(
          %{
            "question" => "Defer composed pixels?",
            "blocking" => true,
            "authority" => "human_required",
            "context" => %{"authority_basis" => "security"},
            "source_id" => "aged"
          },
          ticket: %{identifier: "3141", title: "Renderer", url: nil},
          source: %{agent_id: "codex", session_id: "s-1", event_id: nil},
          now: DateTime.add(DateTime.utc_now(), -20 * 60, :second)
        )

      assert_survives(
        decisions_fun: fn -> {:ok, [decision]} end,
        gates_fun: fn _ticket -> exit(:hints_down) end,
        condition_states_fun: fn topics -> Map.new(topics, &{&1, :unknown}) end
      )
    end

    test "the escalation timer re-arms after each pass" do
      test_pid = self()
      decisions_fun = fn -> send(test_pid, :escalation_pass) && {:ok, []} end
      start_listener(escalation_interval_ms: 10, escalation: [decisions_fun: decisions_fun])

      assert_receive :escalation_pass, 1_000
      assert_receive :escalation_pass, 1_000
    end
  end

  defp assert_survives(escalation) do
    pid = start_listener(escalation_interval_ms: :infinity, escalation: escalation)
    bindings = ExecutorListener.bindings(@listener_name)
    assert "executor.#" in bindings

    log =
      capture_log(fn ->
        send(pid, :escalate)
        assert ExecutorListener.backstop(@listener_name) == :ok
      end)

    assert log =~ "Decision escalation failed"
    assert Process.alive?(pid)
    assert ExecutorListener.bindings(@listener_name) == bindings
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
