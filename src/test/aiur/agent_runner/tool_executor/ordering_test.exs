defmodule Aiur.AgentRunner.ToolExecutor.OrderingTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Events.Exchange
  alias Aiur.Issue

  describe "declare_blocker_for_issue via blocker_declarer closure" do
    test "stalled declare followed by unblock finishes unblocked" do
      issue = %Issue{identifier: "1031"}
      name = Module.concat(__MODULE__, "MutationOrder#{System.unique_integer([:positive])}")
      start_supervised!({Aiur.CoordinationTasks, name: name})
      {:ok, state} = Agent.start_link(fn -> :initial end)
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn key, operation, opts ->
            Aiur.CoordinationTasks.enqueue(key, operation, name, opts)
          end,
          coordination_runner: fn key, operation, opts ->
            Aiur.CoordinationTasks.run(key, operation, name, opts)
          end,
          blocker_subscriber: fn _current, _blocker -> :ok end,
          dependency_declarer: fn _current, _blocker ->
            send(test_pid, {:declare_started, self()})

            receive do
              :release ->
                Agent.update(state, fn _ -> :declared end)
                {:ok, :created}
            end
          end,
          dependency_unblocker: fn _current, _blocker ->
            send(test_pid, :unblock_started)
            Agent.update(state, fn _ -> :unblocked end)
            {:ok, :removed}
          end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:declare_started, worker}, 2_000

      unblock = Task.async(fn -> executor.("aiur_unblock", %{"issue_number" => 999}) end)

      refute_receive :unblock_started, 40
      assert Agent.get(state, & &1) == :initial
      send(worker, :release)

      response = Task.await(unblock)
      assert response["success"]
      assert Jason.decode!(response["output"])["result"] == "removed"
      assert Agent.get(state, & &1) == :unblocked
    end
  end

  describe "prefix_with_ticket_namespace via event_publisher closure" do
    test "bare names are published under ticket.<id>.agent.<name>" do
      identifier = "TE-prefix-#{System.unique_integer([:positive])}"
      # id: nil so issue_identifier/1 falls back to :identifier for topic namespacing
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.agent.#")

      executor.("emit_event", %{"name" => "progress", "message" => "test"})

      assert_receive {:event, %{topic: "ticket." <> _}}, 2_000
    end

    test "ticket.* names pass through the publisher unchanged" do
      identifier = "TE-prefix2-#{System.unique_integer([:positive])}"
      # id: nil so issue_identifier/1 falls back to :identifier for topic namespacing
      issue = %Issue{identifier: identifier}

      Exchange.subscribe("ticket.#{identifier}.agent.#")

      executor = ToolExecutor.build(issue, nil, nil)
      executor.("emit_event", %{"name" => "progress", "message" => "check"})

      assert_receive {:event, %{topic: topic, source: :agent}}, 2_000
      assert topic == "ticket.#{identifier}.agent.progress"
    end
  end
end
