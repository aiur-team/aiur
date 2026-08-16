defmodule Aiur.ExecutorListenerTest do
  use Aiur.TestSupport

  alias Aiur.Config.Paths
  alias Aiur.Decision
  alias Aiur.Events.Exchange
  alias Aiur.ExecutorEvents
  alias Aiur.ExecutorBindings
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox
  alias Aiur.JsonStore

  @listener_name Aiur.ExecutorListener.Test

  setup do
    # The listener reads/writes its durable watermark under the per-test log
    # root (TestSupport isolates :log_file), so a "restart" in a test starts a
    # fresh process over the same watermark.
    previous_health_alert_fun = Application.get_env(:aiur, :executor_listener_health_alert_fun)

    on_exit(fn ->
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

  defp watermark_path do
    Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.executor.listener.watermark.json")
  end

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
    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => first_message}}
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
    assert_receive {:event, %{"topic" => "executor.command.requested", "message" => replayed}}
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

  test "non-executor events become wakes without advancing the command watermark" do
    start_supervised!({ExecutorWakeInbox, debounce_ms: 10})
    start_listener()

    id = System.unique_integer([:positive])

    Exchange.publish("ticket.42.pr.opened", %{
      id: id,
      topic: "ticket.42.pr.opened",
      action: "opened",
      pr: %{"number" => 2030, "draft" => false, "head" => %{"sha" => String.duplicate("a", 40)}}
    })

    assert {:ok, [%{"ticket" => "42", "pr_number" => 2030}]} = ExecutorWakeInbox.wait(500)
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
