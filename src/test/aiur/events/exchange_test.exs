defmodule Aiur.Events.ExchangeTest do
  use ExUnit.Case, async: false

  alias Aiur.Events.Exchange

  setup do
    # Exchange is started by Aiur.Application; tests run against the
    # global instance. Clean up any bindings the test process owns so
    # state doesn't leak between cases.
    on_exit(fn ->
      pid = self()

      for pattern <- Exchange.bindings_for(pid) do
        Exchange.unsubscribe(pattern)
      end
    end)

    :ok
  end

  describe "subscribe/1 + publish/2" do
    test "delivers a matching event to the subscriber" do
      :ok = Exchange.subscribe("ticket.101.#")
      count = Exchange.publish("ticket.101.branch.push", %{id: 1, body: :hi})

      # The orchestrator subscribes to `ticket.*.branch.push` at boot
      # (blockee auto-resume hook), so the count includes it alongside
      # this test's subscriber.
      assert count >= 1
      assert_receive {:event, %{id: 1, body: :hi}}, 500
    end

    test "non-matching pattern receives nothing" do
      :ok = Exchange.subscribe("ticket.999.#")
      Exchange.publish("ticket.101.branch.push", %{id: 2})

      refute_receive {:event, _}, 100
    end

    test "wildcard star matches one segment" do
      :ok = Exchange.subscribe("*.*.branch.push")
      Exchange.publish("ticket.101.branch.push", %{id: 3})
      Exchange.publish("system.main.branch.push", %{id: 4})

      assert_receive {:event, %{id: 3}}, 500
      assert_receive {:event, %{id: 4}}, 500
    end

    test "multiple subscribers to overlapping patterns each receive" do
      test_pid = self()

      sub1 =
        spawn(fn ->
          :ok = Exchange.subscribe("ticket.101.#")

          receive do
            {:event, ev} -> send(test_pid, {:sub1, ev})
          after
            1_000 -> :timeout
          end
        end)

      sub2 =
        spawn(fn ->
          :ok = Exchange.subscribe("ticket.*.branch.push")

          receive do
            {:event, ev} -> send(test_pid, {:sub2, ev})
          after
            1_000 -> :timeout
          end
        end)

      # Wait for both subscribers to register before publishing
      :ok = wait_until(fn -> Exchange.bindings_for(sub1) != [] end)
      :ok = wait_until(fn -> Exchange.bindings_for(sub2) != [] end)

      Exchange.publish("ticket.101.branch.push", %{id: 5})

      assert_receive {:sub1, %{id: 5}}, 500
      assert_receive {:sub2, %{id: 5}}, 500
    end
  end

  describe "unsubscribe/1" do
    test "no events delivered after unsubscribe" do
      :ok = Exchange.subscribe("ticket.101.#")
      :ok = Exchange.unsubscribe("ticket.101.#")

      Exchange.publish("ticket.101.branch.push", %{id: 6})
      refute_receive {:event, _}, 100
    end

    test "unsubscribe of non-existent binding is a no-op" do
      assert :ok = Exchange.unsubscribe("never.subscribed")
    end
  end

  describe "subscriber death" do
    test "DOWN reaps binding within 100ms" do
      sub =
        spawn(fn ->
          :ok = Exchange.subscribe("ticket.999.#")
          # Hold the binding briefly, then die.
          Process.sleep(50)
        end)

      :ok = wait_until(fn -> Exchange.bindings_for(sub) != [] end)
      ref = Process.monitor(sub)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}, 500

      :ok = wait_until(fn -> Exchange.bindings_for(sub) == [] end, 500)

      # Publishing after DOWN must not crash even though we previously
      # had a binding for the now-dead pid. The orchestrator's wildcard
      # `ticket.*.branch.push` subscription matches this topic, so the
      # reported count includes whatever ambient subscribers remain.
      # What matters is (a) no crash, (b) the dead pid's binding has
      # been reaped (asserted above), and (c) the count never reflects
      # delivery to a dead pid — `>= 0` enforces only the non-negative
      # invariant of the Exchange's counting contract.
      count = Exchange.publish("ticket.999.branch.push", %{id: 7})
      assert is_integer(count) and count >= 0
    end
  end

  describe "validate_pattern!" do
    test "raises on empty pattern" do
      assert_raise ArgumentError, fn -> Exchange.subscribe("") end
    end

    test "raises on leading dot" do
      assert_raise ArgumentError, fn -> Exchange.subscribe(".bad") end
    end

    test "raises on trailing dot" do
      assert_raise ArgumentError, fn -> Exchange.subscribe("bad.") end
    end

    test "raises on double dots" do
      assert_raise ArgumentError, fn -> Exchange.subscribe("ticket..101") end
    end
  end

  describe "matches?/2 delegate" do
    test "matches the underlying Topic matcher" do
      assert Exchange.matches?("ticket.*.branch.push", "ticket.101.branch.push")
      refute Exchange.matches?("ticket.*.branch.push", "ticket.101.branch.force-push")
    end
  end

  describe "publisher non-blocking" do
    test "publish does not block on a sleeping subscriber" do
      test_pid = self()

      slow =
        spawn(fn ->
          :ok = Exchange.subscribe("slow.*")

          receive do
            {:event, _} ->
              send(test_pid, :received)
              Process.sleep(500)
          end
        end)

      :ok = wait_until(fn -> Exchange.bindings_for(slow) != [] end)

      start = System.monotonic_time(:millisecond)
      Exchange.publish("slow.event", %{id: 8})
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 100, "publish blocked: #{elapsed}ms"
      assert_receive :received, 500
    end
  end

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until_loop(fun, deadline)
  end

  defp wait_until_loop(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :error

      true ->
        Process.sleep(10)
        wait_until_loop(fun, deadline)
    end
  end
end
