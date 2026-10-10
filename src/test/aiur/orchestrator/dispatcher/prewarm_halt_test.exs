defmodule Aiur.Orchestrator.Dispatcher.PrewarmHaltTest do
  use Aiur.DispatcherTestSupport

  describe "prewarm dispatch halt" do
    test "emits once while prewarm keeps the fleet on hold and rearms after recovery" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      held = Dispatcher.emit_prewarm_blocked_alert(%State{}, :building)
      assert held.prewarm_blocked_alert_active
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"} = event}, 500
      assert event["reason"] =~ "Prewarm build is running"
      assert event["reason"] =~ "monitored build is expected to clear"

      assert Dispatcher.emit_prewarm_blocked_alert(held, :building) == held
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100

      recovered = Dispatcher.clear_prewarm_blocked_alert(held)
      refute recovered.prewarm_blocked_alert_active
      assert recovered.prewarm_blocked_alert_resolution_emitted
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked.resolved"}}, 500

      rearmed = Dispatcher.emit_prewarm_blocked_alert(recovered, :building)
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 500
      refute rearmed.prewarm_blocked_alert_resolution_emitted
    end

    test "checking alert promises bounded fallback and stalled resolution releases dispatch" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      held = Dispatcher.emit_prewarm_blocked_alert(%State{}, :checking)

      receive_barrier({:event, %{topic: "system.dispatch.prewarm_blocked"} = blocked})
      assert blocked["reason"] =~ "remote freshness probe is running"
      assert blocked["reason"] =~ "bounded dispatch watchdog"

      released =
        Dispatcher.clear_prewarm_blocked_alert(
          held,
          {:error, {:repo_base_dispatch_hold_stalled, :checking}}
        )

      refute released.prewarm_blocked_alert_active

      receive_barrier({:event, %{topic: "system.dispatch.prewarm_blocked.resolved"} = resolved})
      assert resolved["reason"] =~ "Prewarm checking stalled"
      assert resolved["reason"] =~ "released the fleet dispatch gate for cold-clone fallback"
    end

    test "watchdog phase broadcast resolves the alert without a successful dispatch poll" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      held = Dispatcher.emit_prewarm_blocked_alert(%State{}, :checking)
      receive_barrier({:event, %{topic: "system.dispatch.prewarm_blocked"}})

      stalled = {:error, {:repo_base_dispatch_hold_stalled, :checking}}
      assert {:noreply, released} = Orchestrator.handle_info({:prewarm_phase, stalled}, held)
      refute released.prewarm_blocked_alert_active

      receive_barrier({:event, %{topic: "system.dispatch.prewarm_blocked.resolved"} = resolved})
      assert resolved["reason"] =~ "Prewarm checking stalled"
    end

    test "the orchestrator is subscribed to prewarm phase broadcasts" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      pid = Process.whereis(Aiur.Orchestrator)
      refute is_nil(pid), "expected the supervised singleton orchestrator to be running"

      # Force a blocked-alert state so the broadcast's effect is observable. If
      # `Lifecycle.subscribe_to_prewarm/1` silently breaks, the stalled broadcast
      # never reaches the orchestrator's handle_info/2 and no resolution event is
      # emitted — the operator keeps staring at the blocked alert.
      :sys.replace_state(pid, fn state ->
        %{state | prewarm_blocked_alert_active: true, prewarm_blocked_alert_resolution_emitted: false}
      end)

      on_exit(fn ->
        if Process.alive?(pid) do
          :sys.replace_state(pid, fn state ->
            %{state | prewarm_blocked_alert_active: false, prewarm_blocked_alert_resolution_emitted: false}
          end)
        end
      end)

      AgentPubSub.broadcast_prewarm_phase({:error, {:repo_base_dispatch_hold_stalled, :checking}})

      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked.resolved"} = resolved}, 2_000
      assert resolved["reason"] =~ "Prewarm checking stalled"

      # The resolution event is emitted by the orchestrator's handle_info/2, so
      # by the time it arrived the state was already flipped.
      refute :sys.get_state(pid).prewarm_blocked_alert_active
    end

    test "a healthy refresh cycle publishes no prewarm_blocked pair" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      with_prewarm_enabled_config()
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}

      # A routine refresh holds the gate for one tick while the freshness probe
      # runs, then resolves to :ready. The hold self-clears within the routine
      # bound, so neither transition may surface a dispatch-gate event.
      held = Dispatcher.dispatch_or_hold(state, [], fn -> :checking end)

      released = Dispatcher.dispatch_or_hold(held, [], fn -> :ready end)

      # The published event list for this topic must be empty for the whole
      # healthy cycle — a count assertion (one fewer event) would pass on the
      # pre-fix code.
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked.resolved"}}, 100

      assert held.prewarm_hold_ticks == 1
      assert is_integer(held.prewarm_hold_since_ms)
      refute held.prewarm_blocked_alert_active

      assert released.prewarm_hold_ticks == 0
      assert released.prewarm_hold_since_ms == nil
      refute released.prewarm_blocked_alert_active
    end

    test "a hold persisting past the routine bound emits exactly one blocked pair" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      with_prewarm_enabled_config()
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1\n"} end)
      Application.put_env(:aiur, :file_descriptor_sample_override, fn -> :unavailable end)

      # A probe that has already gated dispatch past the routine refresh bound
      # (e.g. one exceeding its 30s timeout) is a genuine block, not noise.
      now = System.monotonic_time(:millisecond)

      state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        prewarm_hold_since_ms: now - 16_000
      }

      held = Dispatcher.dispatch_or_hold(state, [], fn -> :checking end)
      assert held.prewarm_blocked_alert_active

      # Still holding: the alert is deduped, not re-published every tick.
      held_again = Dispatcher.dispatch_or_hold(held, [], fn -> :checking end)
      assert held_again.prewarm_blocked_alert_active

      released = Dispatcher.dispatch_or_hold(held_again, [], fn -> :ready end)
      refute released.prewarm_blocked_alert_active
      assert released.prewarm_hold_since_ms == nil

      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"} = blocked}, 500
      assert blocked["reason"] =~ "remote freshness probe is running"

      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked.resolved"} = resolved}, 500
      assert resolved["reason"] =~ "Shared prewarm is ready"

      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked.resolved"}}, 100
    end

    test "maybe_emit_prewarm_blocked_alert debounces routine holds and raises after the bound" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("system.dispatch.prewarm_blocked")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      started = 10_000

      # The first observed hold tick stamps the start; still inside the window.
      first = Dispatcher.maybe_emit_prewarm_blocked_alert(%State{}, :checking, fn -> started end)
      assert first.prewarm_hold_since_ms == started
      refute first.prewarm_blocked_alert_active
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100

      # A hold that clears within the bound emits nothing.
      within_bound = Dispatcher.maybe_emit_prewarm_blocked_alert(first, :checking, fn -> started + 5_000 end)
      assert within_bound.prewarm_hold_since_ms == started
      refute within_bound.prewarm_blocked_alert_active
      refute_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 100

      # Once the hold outlives the bound, the alert raises exactly once.
      crossed = Dispatcher.maybe_emit_prewarm_blocked_alert(within_bound, :checking, fn -> started + 15_000 end)
      assert crossed.prewarm_blocked_alert_active
      assert_receive {:event, %{topic: "system.dispatch.prewarm_blocked"}}, 500
    end
  end
end
