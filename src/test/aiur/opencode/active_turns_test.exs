defmodule Aiur.Opencode.ActiveTurnsTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentRunner, Issue}
  alias Aiur.Opencode.ActiveTurns

  setup do
    # Application starts the GenServer; ensure a fresh-looking table by
    # using unique identifiers per test rather than truncating shared state.
    :ok
  end

  describe "lookup/2" do
    test "returns :not_found for unregistered ids" do
      assert ActiveTurns.lookup("test-#{System.unique_integer()}", "tDEAD") == :not_found
    end

    test "returns :active after put/2" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)

      assert ActiveTurns.lookup(id, turn) == :active
    end

    test "returns {:closed, reason} after mark_closed/3" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)
      :ok = ActiveTurns.mark_closed(id, turn, :done)

      assert ActiveTurns.lookup(id, turn) == {:closed, :done}
    end

    test "mark_closed/3 preserves the reason verbatim" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)
      :ok = ActiveTurns.mark_closed(id, turn, {:failed, :timeout})

      assert ActiveTurns.lookup(id, turn) == {:closed, {:failed, :timeout}}
    end

    test "entries for distinct (identifier, turn) pairs are independent" do
      id_a = "a-#{System.unique_integer()}"
      id_b = "b-#{System.unique_integer()}"
      turn = "t-shared"

      :ok = ActiveTurns.put(id_a, turn)
      assert ActiveTurns.lookup(id_a, turn) == :active
      assert ActiveTurns.lookup(id_b, turn) == :not_found
    end
  end

  describe "cleanup" do
    test "registry restart terminates incumbent runner tasks before accepting replacements" do
      identifier = "AIUR-1030-registry-restart-#{System.unique_integer([:positive])}"
      issue = %Issue{id: identifier, identifier: identifier, title: "Registry restart"}
      test_pid = self()

      {:ok, incumbent} =
        Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
          AgentRunner.run_generation_for_test(issue, fn ->
            Process.flag(:trap_exit, true)
            :ok = ActiveTurns.put(identifier, "tREGISTRY")
            send(test_pid, {:incumbent_ready, self()})

            receive do
              {:EXIT, _supervisor, :shutdown} ->
                send(test_pid, {:incumbent_stopping, self()})

                receive do
                  :finish_shutdown -> :ok
                end
            end
          end)
        end)

      on_exit(fn ->
        if Process.alive?(incumbent), do: Process.exit(incumbent, :kill)
      end)

      incumbent_ref = Process.monitor(incumbent)
      assert_receive {:incumbent_ready, ^incumbent}, 2_000

      registry = Process.whereis(ActiveTurns)
      registry_ref = Process.monitor(registry)
      Process.exit(registry, :kill)

      assert_receive {:DOWN, ^registry_ref, :process, ^registry, :killed}, 2_000
      assert_receive {:incumbent_stopping, ^incumbent}, 2_000
      refute Process.whereis(ActiveTurns)

      send(incumbent, :finish_shutdown)
      assert_receive {:DOWN, ^incumbent_ref, :process, ^incumbent, _reason}, 2_000
      _state = :sys.get_state(Aiur.AgentRunner.Supervisor)

      replacement_registry = Process.whereis(ActiveTurns)
      assert is_pid(replacement_registry)
      refute replacement_registry == registry
      refute Process.alive?(incumbent)

      assert :replacement_started =
               AgentRunner.run_generation_for_test(issue, fn -> :replacement_started end)
    end

    test "cleanup handle_info deletes the entry" do
      id = "test-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)

      # Drive the handle_info path directly without waiting the 60 s timer.
      pid = Process.whereis(ActiveTurns)
      assert is_pid(pid)
      send(pid, {:cleanup, {id, turn}})
      # Round-trip a synchronous call to flush the mailbox so :cleanup ran.
      _ = :sys.get_state(pid)

      assert ActiveTurns.lookup(id, turn) == :not_found
    end

    test "init returns ok state and re-uses existing table" do
      # The Application started the GenServer once already; calling init
      # again should hit the ensure_table fallback (table already exists).
      assert {:ok,
              %{
                generation_leases: %{},
                generation_waiters: %{},
                inactive_waiters: %{},
                owner_refs: %{},
                owners: %{},
                turn_owners: %{}
              }} = ActiveTurns.init([])
    end

    test "mark_closed is safe when GenServer is not registered" do
      # Hit the schedule_cleanup `_ -> :ok` branch (nil pid path) by
      # briefly unregistering the name. Re-register before returning so
      # other tests aren't affected.
      pid = Process.whereis(ActiveTurns)
      assert is_pid(pid)
      Process.unregister(ActiveTurns)

      try do
        id = "test-#{System.unique_integer()}"
        turn = "t-#{System.unique_integer()}"
        :ok = ActiveTurns.put(id, turn)
        assert :ok = ActiveTurns.mark_closed(id, turn, :done)
        assert ActiveTurns.lookup(id, turn) == {:closed, :done}
      after
        Process.register(pid, ActiveTurns)
      end
    end
  end

  describe "register_subscriber/3" do
    test "returns nil when the slot is empty (first bridge to claim it)" do
      id = "rs-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)

      assert {:ok, nil} = ActiveTurns.register_subscriber(id, turn, self())
    end

    test "returns the prior pid when a new bridge claims an already-held slot" do
      id = "rs-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)

      first = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, nil} = ActiveTurns.register_subscriber(id, turn, first)

      assert {:ok, ^first} = ActiveTurns.register_subscriber(id, turn, self())
    after
      :ok
    end

    test "preserves the turn state when displacing a subscriber" do
      id = "rs-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"
      :ok = ActiveTurns.put(id, turn)

      first = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, nil} = ActiveTurns.register_subscriber(id, turn, first)
      {:ok, ^first} = ActiveTurns.register_subscriber(id, turn, self())

      assert ActiveTurns.lookup(id, turn) == :active
    end

    test "register_subscriber works even if put/2 was never called (raced before AgentRunner registered)" do
      # Defensive: bridge may receive the marker before AgentRunner's
      # `put/2`. register_subscriber should still create the row in
      # `:active` state so the slot is owned.
      id = "rs-#{System.unique_integer()}"
      turn = "t-#{System.unique_integer()}"

      assert {:ok, nil} = ActiveTurns.register_subscriber(id, turn, self())
      assert ActiveTurns.lookup(id, turn) == :active
    end
  end
end
