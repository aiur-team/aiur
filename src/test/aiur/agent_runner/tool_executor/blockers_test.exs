defmodule Aiur.AgentRunner.ToolExecutor.BlockersTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.Issue

  describe "declare_blocker_for_issue via blocker_declarer closure" do
    test "returns :no_issue_number failure for an issue with nil identifier" do
      issue = %Issue{id: "gid-te-03", identifier: nil}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("aiur_declare_blocker", %{"issue_number" => 5})

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "no_issue_number"
    end

    test "returns pending without executing the declaration on the RPC path" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn key, operation, opts ->
            send(test_pid, {:enqueued, key, operation, opts})
            :pending
          end
        )

      response = executor.("aiur_declare_blocker", %{"issue_number" => 999})

      assert response["success"] == true
      assert Jason.decode!(response["output"])["result"] == "pending"
      assert_receive {:enqueued, {:ticket, "1031"}, operation, opts}, 2_000
      assert opts[:operation_timeout] == :infinity
      assert opts[:log_context] == %{issue_id: nil, issue_identifier: "1031"}
      assert is_function(operation, 0)
    end

    test "returns within a small bound while dependency declaration is stalled" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          dependency_declarer: fn _current, _blocker ->
            send(test_pid, {:dependency_started, self()})
            receive do: (:release -> {:ok, :created})
          end,
          blocker_subscriber: fn current, blocker ->
            send(test_pid, {:subscribed, current, blocker})
            :ok
          end
        )

      call = Task.async(fn -> executor.("aiur_declare_blocker", %{"issue_number" => 999}) end)

      assert {:ok, response} = Task.yield(call, 2_000)
      assert response["success"] == true
      assert Jason.decode!(response["output"])["result"] == "pending"
      assert_receive {:subscribed, "1031", 999}, 2_000
      assert_receive {:dependency_started, worker}, 2_000
      send(worker, :release)
    end

    test "declare and unblock use the same ordered ticket key" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn key, operation, opts ->
            send(test_pid, {:enqueued, key, operation, opts})
            :pending
          end,
          coordination_runner: fn key, operation, opts ->
            send(test_pid, {:ran, key, operation, opts})
            operation.()
          end,
          dependency_unblocker: fn _current, _blocker -> {:ok, :removed} end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]

      response = executor.("aiur_unblock", %{"issue_number" => 999})
      assert response["success"]
      assert Jason.decode!(response["output"])["result"] == "removed"

      assert_receive {:enqueued, key, _declare, declare_opts}, 2_000
      assert_receive {:ran, ^key, _unblock, unblock_opts}, 2_000
      assert declare_opts == unblock_opts
      assert declare_opts[:operation_timeout] == :infinity
      assert declare_opts[:log_context] == %{issue_id: nil, issue_identifier: "1031"}
    end

    test "blocked publication waits for blocker subscription on the ticket lane" do
      issue = %Issue{id: "gid-1031", identifier: "1031"}
      name = Module.concat(__MODULE__, "SubscriptionOrder#{System.unique_integer([:positive])}")
      start_supervised!({Aiur.CoordinationTasks, name: name})
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn key, operation, opts ->
            Aiur.CoordinationTasks.enqueue(key, operation, name, opts)
          end,
          blocker_subscriber: fn _current, _blocker ->
            send(test_pid, {:subscription_started, self()})
            receive do: (:release -> :ok)
          end,
          dependency_declarer: fn _current, _blocker ->
            send(test_pid, :dependency_declared)
            {:ok, :created}
          end,
          event_bus_publisher: fn topic, _payload, _opts ->
            send(test_pid, {:event_published, topic})
            {:ok, 42, []}
          end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:subscription_started, subscriber}, 2_000

      response = executor.("emit_event", %{"name" => "blocked", "message" => "waiting"})
      assert response["success"]
      refute_receive {:event_published, _topic}, 20

      send(subscriber, :release)
      assert_receive :dependency_declared, 2_000
      assert_receive {:event_published, "ticket.gid-1031.agent.blocked"}, 2_000
    end

    test "unblock preserves terminal success and error results" do
      issue = %Issue{identifier: "1031"}

      for {dependency_result, expected} <- [
            {{:ok, :removed}, {:ok, "removed"}},
            {{:ok, :not_present}, {:ok, "not_present"}},
            {{:error, :rate_limited}, {:error, "API budget"}},
            {{:error, :permission_denied}, {:error, "Issues:write"}},
            {{:error, :dependency_still_present}, {:error, "dependency_still_present"}},
            {{:error, {:postcondition_check_failed, :timeout}}, {:error, "postcondition_check_failed"}}
          ] do
        executor =
          ToolExecutor.build(issue, nil, nil, %{},
            coordination_runner: fn _key, operation, _opts -> operation.() end,
            dependency_unblocker: fn _current, _blocker -> dependency_result end
          )

        response = executor.("aiur_unblock", %{"issue_number" => 999})

        case expected do
          {:ok, result} ->
            assert response["success"]
            assert Jason.decode!(response["output"])["result"] == result

          {:error, detail} ->
            refute response["success"]
            assert Jason.encode!(Jason.decode!(response["output"])) =~ detail
        end
      end
    end

    test "does not report pending when coordination admission fails" do
      issue = %Issue{identifier: "1031"}

      for reason <- [:coordination_overloaded, :coordination_unavailable] do
        executor =
          ToolExecutor.build(issue, nil, nil, %{}, coordination_enqueuer: fn _key, _operation, _opts -> {:error, reason} end)

        response = executor.("aiur_declare_blocker", %{"issue_number" => 999})
        assert response["success"] == false
        assert Jason.decode!(response["output"])["error"]["reason"] =~ Atom.to_string(reason)
      end

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn _key, _operation, _opts ->
            {:error, :coordination_indeterminate}
          end
        )

      response = executor.("aiur_declare_blocker", %{"issue_number" => 999})
      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["message"] =~ "Do not retry"
    end

    test "coordination failures retain subsystem-specific payloads across tools" do
      issue = %Issue{identifier: "1031"}

      for {reason, expected_message} <- [
            {:coordination_overloaded, "at capacity"},
            {:coordination_unavailable, "temporarily unavailable"},
            {:coordination_indeterminate, "timed out"},
            {:coordination_timeout, "operation timeout"}
          ],
          tool <- ["aiur_declare_blocker", "aiur_unblock", "emit_event"] do
        opts = coordination_failure_opts(tool, reason)
        executor = ToolExecutor.build(issue, nil, nil, %{}, opts)
        arguments = coordination_tool_arguments(tool)

        response = executor.(tool, arguments)
        error = Jason.decode!(response["output"])["error"]

        refute response["success"]
        assert error["reason"] == Atom.to_string(reason)
        assert error["message"] =~ expected_message
      end
    end

    test "task exits and operation failures retain structured coordination details" do
      issue = %Issue{identifier: "1031"}

      for {reason, expected_reason, expected_detail} <- [
            {{:coordination_task_exit, :killed}, "coordination_task_exit", "killed"},
            {
              {:coordination_operation_exception, "broken operation"},
              "coordination_operation_exception",
              "broken operation"
            },
            {
              {:coordination_operation_failure, :throw, :bad_state},
              "coordination_operation_failure",
              "bad_state"
            },
            {
              {:coordination_operation_failure, :exit, {:noproc, {GenServer, :call, [:coordination]}}},
              "coordination_operation_failure",
              "noproc"
            }
          ] do
        executor =
          ToolExecutor.build(issue, nil, nil, %{}, coordination_runner: fn _key, _operation, _opts -> {:error, reason} end)

        response = executor.("aiur_unblock", %{"issue_number" => 999})
        error = Jason.decode!(response["output"])["error"]

        refute response["success"]
        assert error["reason"] == expected_reason
        assert Jason.encode!(error["detail"]) =~ expected_detail
        refute error["message"] =~ "Linear"

        if match?({:coordination_operation_failure, :exit, _detail}, reason) do
          assert error["detail"] == %{
                   "kind" => "exit",
                   "detail" => ["noproc", ["Elixir.GenServer", "call", ["coordination"]]]
                 }
        end
      end
    end

    test "unclassified tool failures use a subsystem-neutral fallback" do
      issue = %Issue{identifier: "1031"}

      executor =
        ToolExecutor.build(issue, nil, nil, %{}, coordination_runner: fn _key, _operation, _opts -> {:error, :unexpected_dependency_failure} end)

      response = executor.("aiur_unblock", %{"issue_number" => 999})
      error = Jason.decode!(response["output"])["error"]

      assert error["message"] == "Aiur tool execution failed."
      refute error["message"] =~ "Linear"
    end

    test "coordination timeout does not kill an admitted dependency mutation" do
      issue = %Issue{identifier: "1031"}
      name = Module.concat(__MODULE__, "Timeout#{System.unique_integer([:positive])}")
      start_supervised!({Aiur.CoordinationTasks, name: name, operation_timeout_ms: 20})
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn key, operation, opts ->
            Aiur.CoordinationTasks.enqueue(key, operation, name, opts)
          end,
          blocker_subscriber: fn _current, _blocker ->
            send(test_pid, :subscribed)
            :ok
          end,
          dependency_declarer: fn _current, _blocker ->
            send(test_pid, {:dependency_started, self()})
            receive do: (:release -> {:ok, :created})
          end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive :subscribed, 2_000
      assert_receive {:dependency_started, worker}, 2_000
      worker_ref = Process.monitor(worker)
      refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 40
      assert Process.alive?(Process.whereis(name))
      assert Process.alive?(worker)
      send(worker, :release)
    end

    test "subscription failure prevents declaration" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: capturing_enqueuer(test_pid),
          blocker_subscriber: fn _current, _blocker -> {:error, :disk_busy} end,
          dependency_present: fn _current, _blocker -> {:ok, false} end,
          blocker_unsubscriber: fn current, blocker ->
            send(test_pid, {:unsubscribed, current, blocker})
            :ok
          end,
          dependency_declarer: fn _current, _blocker -> send(test_pid, :unexpected_declare) end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:captured_operation, operation}, 2_000
      assert {:error, {:blocker_subscription_failed, :disk_busy}} = operation.()
      assert_receive {:unsubscribed, "1031", 999}, 2_000
      refute_receive :unexpected_declare, 100
    end

    test "subscription failure retries without removing coverage for an existing dependency" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: capturing_enqueuer(test_pid),
          blocker_subscriber: fn _current, _blocker ->
            Agent.get_and_update(calls, fn
              0 -> {{:error, :disk_busy}, 1}
              count -> {:ok, count + 1}
            end)
          end,
          dependency_present: fn _current, _blocker -> {:ok, true} end,
          blocker_unsubscriber: fn _current, _blocker -> send(test_pid, :unexpected_unsubscribe) end,
          dependency_declarer: fn _current, _blocker -> send(test_pid, :unexpected_declare) end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:captured_operation, operation}, 2_000
      assert :ok = operation.()
      assert Agent.get(calls, & &1) == 2
      refute_receive :unexpected_unsubscribe, 100
      refute_receive :unexpected_declare, 100
    end

    test "failed declaration removes stale subscription when GitHub confirms absence" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: capturing_enqueuer(test_pid),
          blocker_subscriber: fn _current, _blocker -> :ok end,
          dependency_declarer: fn _current, _blocker -> {:error, :timeout} end,
          dependency_present: fn _current, _blocker -> {:ok, false} end,
          blocker_unsubscriber: fn current, blocker ->
            send(test_pid, {:unsubscribed, current, blocker})
            :ok
          end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:captured_operation, operation}, 2_000
      assert {:error, {:blocker_declaration_failed, :timeout}} = operation.()
      assert_receive {:unsubscribed, "1031", 999}, 2_000
    end

    test "ambiguous declaration keeps auto-resume coverage when GitHub confirms presence" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: capturing_enqueuer(test_pid),
          blocker_subscriber: fn current, blocker ->
            send(test_pid, {:subscribed, current, blocker})
            :ok
          end,
          dependency_declarer: fn _current, _blocker -> {:error, :timeout} end,
          dependency_present: fn _current, _blocker -> {:ok, true} end,
          blocker_unsubscriber: fn _current, _blocker -> send(test_pid, :unexpected_unsubscribe) end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:captured_operation, operation}, 2_000
      assert :ok = operation.()
      assert_receive {:subscribed, "1031", 999}, 2_000
      assert_receive {:subscribed, "1031", 999}, 2_000
      refute_receive :unexpected_unsubscribe, 100
    end

    test "failed declaration reports an inconclusive authoritative-state read" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: capturing_enqueuer(test_pid),
          blocker_subscriber: fn _current, _blocker -> :ok end,
          dependency_declarer: fn _current, _blocker -> {:error, :timeout} end,
          dependency_present: fn _current, _blocker -> {:error, :github_unavailable} end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:captured_operation, operation}, 2_000

      assert {:error, {:blocker_reconcile_inconclusive, :timeout, :github_unavailable}} =
               operation.()
    end

    test "failed subscription contains an exception from authoritative-state reconciliation" do
      issue = %Issue{identifier: "1031"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: capturing_enqueuer(test_pid),
          blocker_subscriber: fn _current, _blocker -> {:error, :disk_busy} end,
          dependency_present: fn _current, _blocker -> raise "read failed" end
        )

      assert executor.("aiur_declare_blocker", %{"issue_number" => 999})["success"]
      assert_receive {:captured_operation, operation}, 2_000

      assert {:error, {:blocker_subscription_reconcile_inconclusive, :disk_busy, {:coordination_call_error, "read failed"}}} = operation.()
    end
  end

  defp capturing_enqueuer(test_pid) do
    fn _key, operation, _opts ->
      send(test_pid, {:captured_operation, operation})
      :pending
    end
  end

  defp coordination_failure_opts("aiur_declare_blocker", reason) do
    [coordination_enqueuer: fn _key, _operation, _opts -> {:error, reason} end]
  end

  defp coordination_failure_opts("aiur_unblock", reason) do
    [coordination_runner: fn _key, _operation, _opts -> {:error, reason} end]
  end

  defp coordination_failure_opts("emit_event", reason) do
    [coordination_enqueuer: fn _key, _operation, _opts -> {:error, reason} end]
  end

  defp coordination_tool_arguments("emit_event"),
    do: %{"name" => "progress.checkin", "message" => "testing coordination"}

  defp coordination_tool_arguments(_tool), do: %{"issue_number" => 999}
end
