defmodule Aiur.Events.ExchangeTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Exchange

  setup do
    {:ok, exchange} = start_supervised({Exchange, []})
    %{exchange: exchange}
  end

  test "two unnamed instances start with separate routing state", %{exchange: exchange} do
    {:ok, second} = start_supervised({Exchange, []}, id: :second_unnamed_exchange)

    :ok = subscribe(exchange, "ticket.first.#")
    :ok = subscribe(second, "ticket.second.#")

    assert publish(exchange, "ticket.first.created", %{id: 1}) == 1
    assert_receive {:event, %{id: 1}}
    assert publish(second, "ticket.first.created", %{id: 2}) == 0
  end

  describe "subscribe/2 + publish/3" do
    test "delivers a matching event to the subscriber", %{exchange: exchange} do
      :ok = subscribe(exchange, "ticket.101.#")
      count = publish(exchange, "ticket.101.branch.push", %{id: 1, body: :hi})

      assert count == 1
      assert_receive {:event, %{id: 1, body: :hi}}, 500
    end

    test "non-matching pattern receives nothing", %{exchange: exchange} do
      :ok = subscribe(exchange, "ticket.999.#")
      publish(exchange, "ticket.101.branch.push", %{id: 2})

      refute_receive {:event, _}, 100
    end

    test "wildcard star matches one segment", %{exchange: exchange} do
      :ok = subscribe(exchange, "*.*.branch.push")
      publish(exchange, "ticket.101.branch.push", %{id: 3})
      publish(exchange, "system.main.branch.push", %{id: 4})

      assert_receive {:event, %{id: 3}}, 500
      assert_receive {:event, %{id: 4}}, 500
    end

    test "multiple subscribers to overlapping patterns each receive", %{exchange: exchange} do
      test_pid = self()

      sub1 =
        spawn(fn ->
          :ok = subscribe(exchange, "ticket.101.#")

          receive do
            {:event, ev} -> send(test_pid, {:sub1, ev})
          after
            1_000 -> :timeout
          end
        end)

      sub2 =
        spawn(fn ->
          :ok = subscribe(exchange, "ticket.*.branch.push")

          receive do
            {:event, ev} -> send(test_pid, {:sub2, ev})
          after
            1_000 -> :timeout
          end
        end)

      # Wait for both subscribers to register before publishing
      :ok = wait_until(fn -> bindings_for(exchange, sub1) != [] end)
      :ok = wait_until(fn -> bindings_for(exchange, sub2) != [] end)

      publish(exchange, "ticket.101.branch.push", %{id: 5})

      assert_receive {:sub1, %{id: 5}}, 500
      assert_receive {:sub2, %{id: 5}}, 500
    end
  end

  describe "unsubscribe/2" do
    test "no events delivered after unsubscribe", %{exchange: exchange} do
      :ok = subscribe(exchange, "ticket.101.#")
      :ok = unsubscribe(exchange, "ticket.101.#")

      publish(exchange, "ticket.101.branch.push", %{id: 6})
      refute_receive {:event, _}, 100
    end

    test "unsubscribe of non-existent binding is a no-op", %{exchange: exchange} do
      assert :ok = unsubscribe(exchange, "never.subscribed")
    end
  end

  describe "subscriber death" do
    test "DOWN reaps binding within 100ms", %{exchange: exchange} do
      sub =
        spawn(fn ->
          :ok = subscribe(exchange, "ticket.999.#")
          # Hold the binding briefly, then die.
          Process.sleep(50)
        end)

      :ok = wait_until(fn -> bindings_for(exchange, sub) != [] end)
      ref = Process.monitor(sub)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}, 500

      :ok = wait_until(fn -> bindings_for(exchange, sub) == [] end, 500)

      count = publish(exchange, "ticket.999.branch.push", %{id: 7})
      assert count == 0
    end

    test "reaps every monitor for a subscriber with multiple bindings", %{exchange: exchange} do
      test_pid = self()

      sub =
        spawn(fn ->
          :ok = subscribe(exchange, "ticket.999.#")
          :ok = subscribe(exchange, "ticket.999.branch.push")
          send(test_pid, :subscribed)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscribed, 500
      assert length(bindings_for(exchange, sub)) == 2
      ref = Process.monitor(sub)
      send(sub, :stop)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}, 500

      :ok = wait_until(fn -> bindings_for(exchange, sub) == [] end, 500)
      :ok = wait_until(fn -> :sys.get_state(exchange).monitors == %{} end, 500)
    end
  end

  describe "validate_pattern!" do
    test "raises on empty pattern", %{exchange: exchange} do
      assert_raise ArgumentError, fn -> subscribe(exchange, "") end
    end

    test "raises on leading dot", %{exchange: exchange} do
      assert_raise ArgumentError, fn -> subscribe(exchange, ".bad") end
    end

    test "raises on trailing dot", %{exchange: exchange} do
      assert_raise ArgumentError, fn -> subscribe(exchange, "bad.") end
    end

    test "raises on double dots", %{exchange: exchange} do
      assert_raise ArgumentError, fn -> subscribe(exchange, "ticket..101") end
    end
  end

  describe "matches?/2 delegate" do
    test "matches the underlying Topic matcher" do
      assert Exchange.matches?("ticket.*.branch.push", "ticket.101.branch.push")
      refute Exchange.matches?("ticket.*.branch.push", "ticket.101.branch.force-push")
    end
  end

  describe "publisher non-blocking" do
    test "publish bypasses a suspended exchange mailbox", %{exchange: exchange} do
      :ok = subscribe(exchange, "ticket.101.#")
      :ok = :sys.suspend(exchange)

      on_exit(fn ->
        if Process.alive?(exchange) do
          :sys.resume(exchange)
        end
      end)

      assert publish(exchange, "ticket.101.branch.push", %{id: 8}) == 1
      assert_receive {:event, %{id: 8}}, 500
    end

    test "publish does not block on a sleeping subscriber", %{exchange: exchange} do
      test_pid = self()

      slow =
        spawn(fn ->
          :ok = subscribe(exchange, "slow.*")

          receive do
            {:event, _} ->
              send(test_pid, :received)
              Process.sleep(500)
          end
        end)

      :ok = wait_until(fn -> bindings_for(exchange, slow) != [] end)

      start = System.monotonic_time(:millisecond)
      publish(exchange, "slow.event", %{id: 9})
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

  defp subscribe(exchange, pattern), do: Exchange.subscribe(pattern, exchange)
  defp unsubscribe(exchange, pattern), do: Exchange.unsubscribe(pattern, exchange)
  defp publish(exchange, topic, event), do: Exchange.publish(topic, event, exchange)
  defp bindings_for(exchange, pid), do: Exchange.bindings_for(pid, exchange)
end
