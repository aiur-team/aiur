defmodule Aiur.AgentRunner.ToolExecutorTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.{SessionLifecycle, ToolExecutor}
  alias Aiur.{Boot, DecisionAttention, DecisionStore, EventPublicationLog, Issue, TrackerIdentity}
  alias Aiur.Events.{Exchange, SubscriptionStore}

  describe "build/3" do
    test "returns a 2-arity closure" do
      issue = %Issue{id: "gid-te-01", identifier: "TE-01"}
      executor = ToolExecutor.build(issue, nil, nil)

      assert is_function(executor, 2)
    end

    test "delegates unknown tools to DynamicTool failure response" do
      issue = %Issue{id: "gid-te-02", identifier: "TE-02"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("not_a_real_tool", %{})

      assert response["success"] == false
    end

    test "invocation context preserves normal validation for malformed arguments" do
      issue = %Issue{id: "gid-te-invalid", identifier: "TE-invalid"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = ToolExecutor.execute(executor, "emit_event", :invalid, "call-invalid")

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "expects an object"
    end
  end

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
      refute_receive :unexpected_declare
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
      refute_receive :unexpected_unsubscribe
      refute_receive :unexpected_declare
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
      refute_receive :unexpected_unsubscribe
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

  describe "emit_agent_event via event_publisher closure" do
    test "publish succeeds and returns a result map" do
      identifier = "TE-emit-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-te-06", identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("emit_event", %{"name" => "blocked", "message" => "waiting"})

      assert response["success"] == true
      result = Jason.decode!(response["output"])
      assert result["ok"] == true
      assert result["result"]["status"] == "pending"
    end

    test "returns pending while downstream event work is stalled" do
      identifier = "TE-slow-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, _slug, _question, _opts ->
            send(test_pid, {:downstream_started, self()})

            receive do
              :release -> {:error, :released_for_test}
            end
          end
        )

      call =
        Task.async(fn ->
          executor.("emit_event", %{
            "name" => "attention.slow-store",
            "message" => "wait"
          })
        end)

      assert {:ok, response} = Task.yield(call, 2_000)

      assert response["success"] == true
      assert Jason.decode!(response["output"])["result"]["status"] == "pending"
      assert_receive {:downstream_started, worker}, 2_000
      assert Process.alive?(worker)
      send(worker, :release)
    end

    test "Exchange subscribers receive the event with the namespaced topic" do
      identifier = "TE-recv-#{System.unique_integer([:positive])}"
      # id: nil so issue_identifier/1 falls back to :identifier; no issue_number
      # passed to Publisher so tracked?(nil) = true → passes contamination filter
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.#")

      executor.("emit_event", %{"name" => "unblocked", "message" => "done waiting"})

      assert_receive {:event, event}, 2_000
      assert event.topic =~ "ticket."
      assert event["name"] == "unblocked"
    end

    test "progress events carry the trusted issue identity and safe invocation provenance" do
      identifier = "TE-observation-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservation", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      # Keep :id nil so this focused producer test is independent of the
      # shared Publisher tracked-set fixture; the BO-004 identity is explicit.
      issue = %{identifier: identifier, tracker_identity: identity}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "session-observation"}, attempt_id: 1)
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress")

      ToolExecutor.execute(executor, "emit_event", %{"name" => "progress", "message" => "private", "payload" => %{"percent" => 50}}, "tool-observation")

      assert_receive {:event, %{ticket_observation: observation}}, 2_000
      assert observation.status == :joinable
      assert observation.tracker_identity == identity
      assert observation.attributes == %{percent: 50}
      assert observation.provenance.attempt == 1
      assert observation.provenance.session_id == "session-observation"
      assert observation.provenance.source_event_id == "tool-observation"
      refute Jason.encode!(observation) =~ "private"
    end

    test "queued events capture occurrence time at admission" do
      identifier = "TE-chronology-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn _key, operation, _opts ->
            send(test_pid, {:captured_event_operation, operation})
            :pending
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress")

      response = executor.("emit_event", %{"name" => "progress", "message" => "queued"})
      admitted_at = DateTime.utc_now()

      assert response["success"]
      assert_receive {:captured_event_operation, operation}, 2_000
      operation.()

      assert_receive {:event, %{ticket_observation: observation}}, 2_000
      assert DateTime.compare(observation.occurred_at, admitted_at) in [:lt, :eq]
      assert DateTime.compare(observation.observed_at, admitted_at) in [:gt, :eq]
    end

    test "queued events persist call-correlated publication completion" do
      identifier = "TE-publication-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-publication-success", identifier: identifier}
      test_pid = self()
      workspace = Path.join(System.tmp_dir!(), "aiur-publication-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(workspace) end)

      executor =
        ToolExecutor.build(issue, workspace, nil, %{},
          coordination_enqueuer: fn _key, operation, opts ->
            send(test_pid, {:captured_event_operation, operation, opts})
            :pending
          end,
          event_bus_publisher: fn topic, _payload, _opts -> {:ok, 4242, topic} end,
          event_publication_recorder: publication_recorder(workspace)
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "progress.checkin", "message" => "queued", "payload" => %{"percent" => 70}},
          "call-progress-70"
        )

      assert response["success"]
      assert_receive {:captured_event_operation, operation, opts}, 2_000
      assert opts[:operation_timeout] == :infinity

      assert opts[:log_context] == %{
               issue_id: "gid-publication-success",
               issue_identifier: identifier
             }

      assert :ok = operation.()

      [record] =
        workspace
        |> Path.join("logs/event-publications.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert record["event"] == "event_publication_completed"
      assert record["tool_call_id"] == "call-progress-70"
      assert record["event_id"] == 4242
      assert record["issue_id"] == "gid-publication-success"
      assert record["issue_identifier"] == identifier
      assert record["topic"] == "ticket.gid-publication-success.agent.progress.checkin"
    end

    test "queued events persist call-correlated terminal publication failure" do
      identifier = "TE-publication-failure-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-publication-failure", identifier: identifier}
      test_pid = self()
      workspace = Path.join(System.tmp_dir!(), "aiur-publication-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(workspace) end)

      executor =
        ToolExecutor.build(issue, workspace, nil, %{},
          coordination_enqueuer: fn _key, operation, _opts ->
            send(test_pid, {:captured_event_operation, operation})
            :pending
          end,
          event_bus_publisher: fn _topic, _payload, _opts -> {:error, :disk_full} end,
          event_publication_recorder: publication_recorder(workspace)
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "progress.checkin", "message" => "queued", "payload" => %{"percent" => 71}},
          "call-progress-71"
        )

      assert response["success"]
      assert_receive {:captured_event_operation, operation}, 2_000
      operation.()

      [record] =
        workspace
        |> Path.join("logs/event-publications.ndjson")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert record["event"] == "event_publication_failed"
      assert record["tool_call_id"] == "call-progress-71"
      assert record["event_id"] == nil
      assert record["issue_id"] == "gid-publication-failure"
      assert record["issue_identifier"] == identifier
      assert record["reason"] =~ "publisher_returned"
      assert record["reason"] =~ "disk_full"
    end

    test "raised, exited, and thrown publisher failures persist sanitized terminal outcomes" do
      secret = "ghp_" <> String.duplicate("a", 36)

      publishers = [
        {"raise", fn _topic, _payload, _opts -> raise "publisher exploded #{secret}" end, "publisher_exception"},
        {"exit", fn _topic, _payload, _opts -> exit({:publisher_down, secret}) end, "publisher_failure, :exit"},
        {"throw", fn _topic, _payload, _opts -> throw({:publisher_rejected, secret}) end, "publisher_failure, :throw"}
      ]

      for {label, publisher, expected_failure} <- publishers do
        identifier = "TE-publication-#{label}-#{System.unique_integer([:positive])}"
        issue = %Issue{id: "gid-#{label}", identifier: identifier}
        test_pid = self()
        workspace = Path.join(System.tmp_dir!(), "aiur-publication-#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf!(workspace) end)

        executor =
          ToolExecutor.build(issue, workspace, nil, %{},
            coordination_enqueuer: fn _key, operation, _opts ->
              send(test_pid, {:captured_event_operation, operation})
              :pending
            end,
            event_bus_publisher: publisher,
            event_publication_recorder: publication_recorder(workspace)
          )

        response =
          ToolExecutor.execute(
            executor,
            "emit_event",
            %{"name" => "progress.checkin", "message" => "queued", "payload" => %{"percent" => 72}},
            "call-progress-#{label}"
          )

        assert response["success"]
        assert_receive {:captured_event_operation, operation}, 2_000
        assert {:error, {:event_publication_failed, failure}} = operation.()
        assert failure =~ expected_failure

        [record] = publication_records(workspace)
        assert record["event"] == "event_publication_failed"
        assert record["tool_call_id"] == "call-progress-#{label}"
        assert record["reason"] =~ expected_failure
        assert record["reason"] =~ "[REDACTED:ghp]"
        refute record["reason"] =~ secret
        assert String.length(record["reason"]) <= 500
      end
    end

    test "queued publication failures log sanitized issue context and actual timeout" do
      name = Module.concat(__MODULE__, "PublicationLog#{System.unique_integer([:positive])}")
      start_supervised!({Aiur.CoordinationTasks, name: name})
      secret = "ghp_" <> String.duplicate("c", 36)
      issue = %Issue{id: "gid-publication-log", identifier: "AIUR-PUBLICATION-LOG"}
      workspace = Path.join(System.tmp_dir!(), "aiur-publication-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(workspace) end)

      executor =
        ToolExecutor.build(issue, workspace, nil, %{},
          coordination_enqueuer: fn key, operation, opts ->
            Aiur.CoordinationTasks.enqueue(key, operation, name, opts)
          end,
          event_bus_publisher: fn _topic, _payload, _opts -> {:error, {:disk_failed, secret}} end,
          event_publication_recorder: publication_recorder(workspace)
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          response =
            ToolExecutor.execute(
              executor,
              "emit_event",
              %{"name" => "progress.checkin", "message" => "queued", "payload" => %{"percent" => 74}},
              "call-progress-log"
            )

          assert response["success"]
          assert :drained = Aiur.CoordinationTasks.run({:ticket, "gid-publication-log"}, fn -> :drained end, name)
        end)

      assert log =~ ~s(key={:ticket, "gid-publication-log"})
      assert log =~ ~s(ticket="gid-publication-log")
      assert log =~ ~s(issue_id="gid-publication-log")
      assert log =~ ~s(issue_identifier="AIUR-PUBLICATION-LOG")
      assert log =~ "event_publication_failed"
      assert log =~ "timeout_ms=infinity"
      assert log =~ "[REDACTED:ghp]"
      refute log =~ secret

      [record] = publication_records(workspace)
      assert record["event"] == "event_publication_failed"
      assert record["tool_call_id"] == "call-progress-log"
    end

    test "publication recorder failures log sanitized issue context" do
      secret = "ghp_" <> String.duplicate("d", 36)
      issue = %Issue{id: "gid-recorder-log", identifier: "AIUR-RECORDER-LOG"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn _key, operation, _opts ->
            send(test_pid, {:captured_event_operation, operation})
            :pending
          end,
          event_bus_publisher: fn _topic, _payload, _opts -> {:ok, 4245, []} end,
          event_publication_recorder: fn _record -> {:error, {:disk_failed, secret}} end
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "progress.checkin", "message" => "queued", "payload" => %{"percent" => 75}},
          "call-recorder-log"
        )

      assert response["success"]
      assert_receive {:captured_event_operation, operation}, 2_000

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:event_publication_record_failed, failure}} = operation.()
          assert failure =~ "[REDACTED:ghp]"
        end)

      assert log =~ ~s(key={:ticket, "gid-recorder-log"})
      assert log =~ ~s(ticket="gid-recorder-log")
      assert log =~ ~s(issue_id="gid-recorder-log")
      assert log =~ ~s(issue_identifier="AIUR-RECORDER-LOG")
      assert log =~ ~s(tool_call_id="call-recorder-log")
      assert log =~ "timeout_ms=infinity"
      assert log =~ "[REDACTED:ghp]"
      refute log =~ secret
    end

    test "successful attention publication resolves locally before outcome recording completes" do
      issue = %Issue{id: "gid-recorder-resolution", identifier: "AIUR-RECORDER-RESOLUTION"}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          coordination_enqueuer: fn _key, operation, _opts ->
            send(test_pid, {:captured_event_operation, operation})
            :pending
          end,
          event_bus_publisher: fn _topic, _payload, _opts -> {:ok, 4246, []} end,
          event_publication_recorder: fn _record ->
            send(test_pid, {:publication_recorder_started, self()})
            receive do: (:release_publication_recorder -> {:error, :disk_failed})
          end,
          attention_resolver: fn resolved_issue, slug ->
            send(test_pid, {:attention_resolved, resolved_issue.identifier, slug})
            :ok
          end
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "attention.resolved",
            "message" => "resolved",
            "payload" => %{"slug" => "scope-question"}
          },
          "call-recorder-resolution"
        )

      assert response["success"]
      assert_receive {:captured_event_operation, operation}, 2_000
      operation_call = Task.async(operation)
      assert_receive {:attention_resolved, "AIUR-RECORDER-RESOLUTION", "scope-question"}, 2_000
      assert_receive {:publication_recorder_started, recorder}, 2_000
      send(recorder, :release_publication_recorder)
      assert {:error, {:event_publication_record_failed, _failure}} = Task.await(operation_call, 2_000)
    end

    test "remote workers persist locally-known publication outcomes outside their transcript" do
      identifier = "TE-publication-remote-#{System.unique_integer([:positive])}"
      issue = %Issue{id: "gid-publication-remote", identifier: identifier}
      test_pid = self()
      workspace = Path.join(System.tmp_dir!(), "aiur-publication-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(workspace) end)

      executor =
        ToolExecutor.build(issue, workspace, "remote.example.com", %{},
          coordination_enqueuer: fn _key, operation, _opts ->
            send(test_pid, {:captured_event_operation, operation})
            :pending
          end,
          event_bus_publisher: fn _topic, _payload, _opts -> {:ok, 4244, []} end,
          event_publication_recorder: publication_recorder(workspace)
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "progress.checkin", "message" => "queued", "payload" => %{"percent" => 73}},
          "call-progress-remote"
        )

      assert response["success"]
      assert_receive {:captured_event_operation, operation}, 2_000
      assert :ok = operation.()

      [record] = publication_records(workspace)
      assert record["event"] == "event_publication_completed"
      assert record["event_id"] == 4244
      refute File.exists?(Path.join(workspace, "logs/agent.ndjson"))
      refute File.exists?(Path.join(workspace, "logs/agent.md"))
    end

    test "progress check-ins and phase updates preserve retry provenance without changing identity" do
      identifier = "TE-observation-retry-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservationRetry", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      issue = %{identifier: identifier, tracker_identity: identity}

      publish = fn name, session_id, attempt, invocation_id ->
        topic = "ticket.#{identifier}.agent.#{name}"
        executor = ToolExecutor.build(issue, nil, nil, %{thread_id: session_id}, attempt_id: attempt)
        :ok = Exchange.subscribe(topic)

        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => name, "message" => "private", "payload" => %{"percent" => 60}},
          invocation_id
        )

        assert_receive {:event, %{ticket_observation: observation}}, 2_000
        assert observation.status == :joinable
        assert observation.attributes == %{percent: 60}
        observation
      end

      first = publish.("progress.checkin", "session-first", 1, "tool-first")
      retry = publish.("progress.phase", "session-retry", 2, "tool-retry")

      assert first.tracker_identity == retry.tracker_identity
      assert first.provenance.attempt == 1
      assert retry.provenance.attempt == 2
      assert first.provenance.session_id == "session-first"
      assert retry.provenance.session_id == "session-retry"
      assert first.provenance.source_event_id == "tool-first"
      assert retry.provenance.source_event_id == "tool-retry"
    end

    test "producer observations retain identity across a Boot restart" do
      identifier = "TE-observation-restart-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservationRestart", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      topic = "ticket.#{identifier}.agent.progress.checkin"
      issue = %{identifier: identifier, tracker_identity: identity}
      :ok = Exchange.subscribe(topic)

      publish = fn session_id, attempt, invocation_id ->
        executor = ToolExecutor.build(issue, nil, nil, %{thread_id: session_id}, attempt_id: attempt)

        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "progress.checkin", "message" => "private", "payload" => %{"percent" => 60}},
          invocation_id
        )

        assert_receive {:event, %{ticket_observation: observation}}, 2_000
        observation
      end

      first = publish.("session-before-restart", 1, "tool-before-restart")
      assert :ok = Boot.remark()
      restarted = publish.("session-after-restart", 2, "tool-after-restart")

      assert first.tracker_identity == restarted.tracker_identity
      refute first.provenance.run_id == restarted.provenance.run_id
      assert first.provenance.attempt == 1
      assert restarted.provenance.attempt == 2
      assert first.provenance.session_id == "session-before-restart"
      assert restarted.provenance.session_id == "session-after-restart"
    end

    test "alerts attach typed stage and safe evidence observations with retry provenance" do
      identifier = "TE-observation-alert-#{System.unique_integer([:positive])}"

      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"node_id" => "I_kwDOObservationAlert", "number" => 42},
          {"owner", "repo"},
          {"owner", "repo"}
        )

      # Alerts pass an Issue struct's identifier through the Publisher's
      # contamination filter. A map keeps this focused adapter test independent
      # of the shared tracked-set fixture while retaining trusted identity.
      issue = %{identifier: identifier, tracker_identity: identity}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "session-alert"}, attempt_id: 3)

      for {name, expected_attributes} <- [
            {"phase.review.end", %{stage: :review, transition: :end}},
            {"evidence.safe", %{needs_attention: true, severity: "warning"}}
          ] do
        topic = "ticket.#{identifier}.agent.#{name}"
        :ok = Exchange.subscribe(topic)

        assert ToolExecutor.execute(
                 executor,
                 "emit_alert",
                 %{
                   "name" => name,
                   "message" => "private evidence",
                   "reason" => "private reason",
                   "needs_attention" => true,
                   "severity" => "warning"
                 },
                 "alert-#{name}"
               )["success"] == true

        assert_receive {:event, %{ticket_observation: observation}}, 2_000
        assert observation.status == :joinable
        assert observation.attributes == expected_attributes
        assert observation.provenance.attempt == 3
        assert observation.provenance.session_id == "session-alert"
        assert observation.provenance.source_event_id == "alert-#{name}"
        refute Jason.encode!(observation) =~ "private"
      end
    end

    test "event and alert producers leave missing trusted identity unattributed" do
      identifier = "TE-observation-unattributed-#{System.unique_integer([:positive])}"
      issue = %{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "session-unattributed"}, attempt_id: 1)

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.progress.checkin")
      ToolExecutor.execute(executor, "emit_event", %{"name" => "progress.checkin", "message" => "private", "payload" => %{"percent" => 50}}, "event-unattributed")
      assert_receive {:event, %{ticket_observation: %{status: :unattributed}}}, 2_000

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.evidence.safe")

      assert ToolExecutor.execute(
               executor,
               "emit_alert",
               %{
                 "name" => "evidence.safe",
                 "message" => "private",
                 "reason" => "private",
                 "needs_attention" => false
               },
               "alert-unattributed"
             )["success"] == true

      assert_receive {:event, %{ticket_observation: %{status: :unattributed}}}, 2_000
    end

    test "attention events create and resolve a durable decision attention" do
      identifier = "TE-attention-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      assert executor.("emit_event", %{"name" => "attention.scope-question", "message" => "Approve the target?"})["success"] == true
      assert :drained = Aiur.CoordinationTasks.run({:ticket, identifier}, fn -> :drained end)
      assert open_attentions(identifier) == ["scope-question"]

      assert executor.("emit_event", %{"name" => "attention.resolved", "message" => "Approved", "payload" => %{"slug" => "scope-question"}})["success"] == true
      assert :drained = Aiur.CoordinationTasks.run({:ticket, identifier}, fn -> :drained end)
      assert open_attentions(identifier) == []
    end

    test "operator-decision pause requests raise a durable attention" do
      identifier = "TE-decision-pause-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      assert executor.(
               "emit_event",
               %{
                 "name" => "pause.request",
                 "message" => "Should this facade target change?",
                 "payload" => %{"reason" => "operator_decision"}
               }
             )["success"] == true

      assert :drained = Aiur.CoordinationTasks.run({:ticket, identifier}, fn -> :drained end)
      assert open_attentions(identifier) == ["operator-decision"]
      assert executor.("emit_event", %{"name" => "attention.resolved", "message" => "Approved", "payload" => %{"slug" => "operator-decision"}})["success"] == true
    end

    test "legacy attention persistence precedes generic event publication and returns Decision correlation" do
      identifier = "TE-attention-order-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      test_pid = self()

      attention_opener = fn _issue, _workspace, _worker_host, slug, question, opts ->
        send(test_pid, {:projected_attention, slug, question, opts})
        {:ok, %{status: :accepted, decision: %{decision_id: "dec_order", version: 1}}}
      end

      executor = ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-1"}, attention_opener: attention_opener)
      :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.scope-question")

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{"name" => "attention.scope-question", "message" => "Approve the target?"},
          "call-attention"
        )

      assert_receive {:projected_attention, "scope-question", "Approve the target?", opts}, 2_000
      assert opts[:source].session_id == "thread-1"
      assert opts[:source].event_id == "call-attention"
      assert_receive {:event, %{topic: "ticket." <> _}}, 2_000

      result = Jason.decode!(response["output"])["result"]
      assert result["status"] == "pending"
    end

    test "an overlong attention still publishes its generic operator signal when projection fails" do
      identifier = "TE-attention-fail-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      question = String.duplicate("x", 2_001)

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, _slug, ^question, _opts ->
            {:error, {:decision_invalid, {:question, :too_long}}}
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.scope-question")

      response =
        executor.("emit_event", %{
          "name" => "attention.scope-question",
          "message" => question
        })

      assert response["success"] == true

      expected_topic = "ticket.#{identifier}.agent.attention.scope-question"
      assert_receive {:event, %{topic: ^expected_topic}}, 2_000
    end

    test "a control-character operator-decision block still publishes when projection fails" do
      identifier = "TE-blocked-fail-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      question = "Approve this?\u0007"

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, "operator-decision", ^question, _opts ->
            {:error, {:decision_invalid, {:question, :unsafe_characters}}}
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.blocked")

      response =
        executor.("emit_event", %{
          "name" => "blocked",
          "message" => "Waiting for a decision",
          "payload" => %{"reason" => "operator_decision", "question" => question}
        })

      assert response["success"] == true
      expected_topic = "ticket.#{identifier}.agent.blocked"
      assert_receive {:event, %{topic: ^expected_topic}}, 2_000
    end

    test "ordinary blocked events do not enter the legacy Decision adapter" do
      identifier = "TE-blocked-no-decision-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_opener: fn _issue, _workspace, _worker_host, _slug, _question, _opts ->
            send(test_pid, :unexpected_attention_projection)
            {:error, :unexpected}
          end
        )

      assert executor.("emit_event", %{"name" => "blocked", "message" => "Waiting for a dependency"})["success"] == true
      refute_receive :unexpected_attention_projection
    end

    test "a resolution timeout cannot suppress the published resolved event or exit the caller" do
      identifier = "TE-resolution-timeout-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      blocked_registry = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(blocked_registry, :stop) end)

      executor =
        ToolExecutor.build(issue, nil, nil, %{},
          attention_resolver: fn _issue, _slug ->
            GenServer.call(blocked_registry, :resolve, 10)
          end
        )

      :ok = Exchange.subscribe("ticket.#{identifier}.agent.attention.resolved")

      response =
        executor.("emit_event", %{
          "name" => "attention.resolved",
          "message" => "Resolved",
          "payload" => %{"slug" => "scope-question"}
        })

      assert response["success"] == true
      assert Process.alive?(self())

      expected_topic = "ticket.#{identifier}.agent.attention.resolved"
      assert_receive {:event, %{topic: ^expected_topic}}, 2_000
    end
  end

  describe "decision.requested routes through Aiur.DecisionStore" do
    test "persists and returns the accepted decision_id/version/status" do
      identifier = "TE-decision-req-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier, title: "Test ticket", url: "https://example.com/#{identifier}"}
      executor = ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-abc"})

      response =
        executor.("emit_event", %{
          "name" => "decision.requested",
          "message" => "Deploy now?",
          "payload" => %{"blocking" => true}
        })

      assert response["success"] == true
      result = Jason.decode!(response["output"])["result"]
      assert result["status"] == "accepted"
      assert result["version"] == 1
      assert is_binary(result["decision_id"])

      {:ok, decision} = Aiur.DecisionStore.get(result["decision_id"])
      assert decision.question == "Deploy now?"
      assert decision.ticket.identifier == identifier
      assert decision.source.agent_id == "codex"
      assert decision.source.session_id == "thread-abc"
    end

    test "captures only trusted runtime/session provenance" do
      identifier = "TE-decision-provenance-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      executor =
        ToolExecutor.build(issue, nil, nil, %{
          backend: "codex",
          model: "gpt-5.6-terra",
          thread_id: "thread-abc",
          attempt_id: "attempt-123",
          account: "operator@example.com",
          raw_session: %{prompt: "do not persist", credential: "secret"},
          capability_url: "https://capability.example/token"
        })

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Use the trusted session?",
        "payload" => %{
          "blocking" => true,
          "provenance" => %{
            "backend" => "forged",
            "requested_model" => "forged-model",
            "session_id" => "forged-session",
            "account" => "operator@example.com",
            "raw_session" => %{"prompt" => "do not persist"},
            "capability_url" => "https://capability.example/token"
          }
        }
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance.agent_family == "codex"
      assert decision.provenance.backend == "codex"
      assert decision.provenance.requested_model == "gpt-5.6-terra"
      assert decision.provenance.session_id == "thread-abc"
      assert decision.provenance.attempt_id == "attempt-123"
      assert decision.provenance.resolved_model == nil

      assert Aiur.DecisionProvenance.to_json_safe(decision.provenance)
             |> Map.keys()
             |> Enum.sort() ==
               [
                 "agent_family",
                 "attempt_id",
                 "backend",
                 "captured_at",
                 "requested_model",
                 "schema_version",
                 "session_id",
                 "source"
               ]
    end

    test "leaves provenance unknown when runner context is unavailable" do
      identifier = "TE-decision-provenance-unknown-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{})

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Accept without runtime context?",
        "payload" => %{"blocking" => true}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance == nil
    end

    test "captures the actual fallback backend rather than the failed transport" do
      identifier = "TE-decision-provenance-fallback-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}

      start_fun = fn _workspace, opts ->
        case Keyword.fetch!(opts, :backend) do
          "claude-repl" -> {:error, :repl_not_ready}
          "claude" -> {:ok, %{model: "sonnet", thread_id: "thread-fallback"}}
        end
      end

      assert {:ok, session} =
               SessionLifecycle.start_agent_session(
                 "/ws",
                 [backend: "claude-repl", model: "sonnet", attempt_id: "attempt-fallback"],
                 start_fun
               )

      executor = ToolExecutor.build(issue, nil, nil, session)

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Use the active backend?",
        "payload" => %{"blocking" => true}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.provenance.agent_family == "claude"
      assert decision.provenance.backend == "claude"
      assert decision.provenance.requested_model == "sonnet"
      assert decision.provenance.attempt_id == "attempt-fallback"
    end

    test "an omitted payload question falls back to the tool message" do
      identifier = "TE-decision-msg-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Use the required tool message?",
        "payload" => %{"blocking" => false}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.question == "Use the required tool message?"
    end

    test "the agent-supplied ticket/source in payload cannot override the trusted issue context" do
      identifier = "TE-decision-trust-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      executor.("emit_event", %{
        "name" => "decision.requested",
        "message" => "Q?",
        "payload" => %{"blocking" => true, "ticket" => %{"identifier" => "attacker"}}
      })

      [decision] = Aiur.DecisionStore.list() |> Enum.filter(&(&1.ticket.identifier == identifier))
      assert decision.ticket.identifier == identifier
    end

    test "a repeat with the same source_id is deduplicated, not re-accepted" do
      identifier = "TE-decision-dedup-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)
      payload = %{"blocking" => true, "source_id" => "retry-key"}

      first = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => payload})
      second = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => payload})

      assert Jason.decode!(first["output"])["result"]["status"] == "accepted"
      assert Jason.decode!(second["output"])["result"]["status"] == "duplicate"
    end

    test "the trusted session and tool-call id deduplicate retries without agent source_id" do
      identifier = "TE-decision-trusted-dedup-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-abc"})

      arguments = %{
        "name" => "decision.requested",
        "message" => "Q?",
        "payload" => %{"blocking" => true, "source_id" => "agent-controlled"}
      }

      first = ToolExecutor.execute(executor, "emit_event", arguments, "call-1")
      retry = ToolExecutor.execute(executor, "emit_event", arguments, "call-1")
      distinct_call = ToolExecutor.execute(executor, "emit_event", arguments, "call-2")

      first_result = Jason.decode!(first["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]
      distinct_result = Jason.decode!(distinct_call["output"])["result"]

      assert first_result["status"] == "accepted"
      assert retry_result["status"] == "duplicate"
      assert retry_result["decision_id"] == first_result["decision_id"]
      assert distinct_result["status"] == "accepted"
      refute distinct_result["decision_id"] == first_result["decision_id"]
    end

    test "trusted identity overwrites atom-keyed agent source_id values" do
      identifier = "TE-decision-atom-source-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-abc"})

      arguments = fn source_id ->
        %{
          "name" => "decision.requested",
          "message" => "Q?",
          "payload" => %{blocking: true, source_id: source_id}
        }
      end

      first = ToolExecutor.execute(executor, "emit_event", arguments.("agent-one"), "call-atom")
      retry = ToolExecutor.execute(executor, "emit_event", arguments.("agent-two"), "call-atom")

      first_result = Jason.decode!(first["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]

      assert first_result["status"] == "accepted"
      assert retry_result["status"] == "duplicate"
      assert retry_result["decision_id"] == first_result["decision_id"]
    end

    test "a structured request enriches its legacy attention instead of duplicating it" do
      identifier = "TE-decision-attention-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier, title: "Adapter ticket"}
      coordination = Module.concat(__MODULE__, "DecisionCorrelation#{System.unique_integer([:positive])}")
      start_supervised!({Aiur.CoordinationTasks, name: coordination})
      test_pid = self()

      executor =
        ToolExecutor.build(issue, nil, nil, %{backend: "codex", thread_id: "thread-adapter"},
          coordination_enqueuer: fn key, operation, opts ->
            Aiur.CoordinationTasks.enqueue(key, operation, coordination, opts)
          end,
          coordination_runner: fn key, operation, opts ->
            Aiur.CoordinationTasks.run(key, operation, coordination, opts)
          end,
          attention_opener: fn issue, workspace, worker_host, slug, question, opts ->
            send(test_pid, {:attention_projection_started, self()})
            receive do: (:release_attention_projection -> :ok)
            DecisionAttention.open_with_decision(issue, workspace, worker_host, slug, question, opts)
          end
        )

      legacy =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "attention.scope-question",
            "message" => "Which scope owns this?"
          },
          "call-legacy"
        )

      legacy_result = Jason.decode!(legacy["output"])["result"]
      assert legacy_result["status"] == "pending"
      assert_receive {:attention_projection_started, projection_worker}, 2_000

      structured_arguments = %{
        "name" => "decision.requested",
        "message" => "Which scope owns this?",
        "payload" => %{
          "attention_slug" => "scope-question",
          "decision_id" => "dec_attacker",
          "source_id" => "attacker-controlled",
          "legacy_attention" => %{
            "slug" => "other",
            "topic" => "ticket.attacker.agent.attention.other"
          },
          "blocking" => true,
          "kind" => "architecture",
          "context" => %{"short_summary" => "Two owners are viable."},
          "options" => [%{"id" => "runtime", "label" => "Runtime"}]
        }
      }

      enrich_call =
        Task.async(fn -> ToolExecutor.execute(executor, "emit_event", structured_arguments, "call-enrich") end)

      assert :ok = wait_for_coordination_queue(coordination, {:ticket, identifier})
      send(projection_worker, :release_attention_projection)

      enriched = Task.await(enrich_call, 2_000)
      retry = ToolExecutor.execute(executor, "emit_event", structured_arguments, "call-enrich")

      assert enriched["success"] == true, enriched["output"]
      assert retry["success"] == true, retry["output"]

      enriched_result = Jason.decode!(enriched["output"])["result"]
      retry_result = Jason.decode!(retry["output"])["result"]

      legacy_decision =
        DecisionStore.list()
        |> Enum.find(&(&1.ticket.identifier == identifier))

      assert enriched_result["decision_id"] == legacy_decision.decision_id
      assert enriched_result["version"] == 2
      assert enriched_result["status"] == "accepted"
      assert retry_result["decision_id"] == legacy_decision.decision_id
      assert retry_result["version"] == 2
      assert retry_result["status"] == "duplicate"

      {:ok, history} = DecisionStore.history(legacy_decision.decision_id)
      assert Enum.map(history, & &1.version) == [1, 2]
      assert List.last(history).options != []

      assert [current] =
               DecisionStore.list()
               |> Enum.filter(&(&1.ticket.identifier == identifier))

      assert current.decision_id == legacy_decision.decision_id
      assert current.source_id == "legacy_attention:scope-question"
      assert current.legacy_attention.topic == "ticket.#{identifier}.agent.attention.scope-question"
    end

    test "an unknown attention slug cannot create a correlated structured Decision" do
      identifier = "TE-decision-attention-missing-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-adapter"})

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "decision.requested",
            "message" => "Which scope owns this?",
            "payload" => %{"attention_slug" => "missing", "blocking" => true}
          },
          "call-missing"
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "not_found"

      refute Enum.any?(DecisionStore.list(), &(&1.ticket.identifier == identifier))
    end

    test "a non-scalar protocol call id cannot crash decision execution" do
      identifier = "TE-decision-call-shape-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil, %{thread_id: "thread-abc"})

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "decision.requested",
            "message" => "Q?",
            "payload" => %{"blocking" => true}
          },
          %{"unexpected" => "shape"}
        )

      assert response["success"] == true
      assert Jason.decode!(response["output"])["result"]["status"] == "accepted"
    end

    test "an invalid request fails without publishing a duplicate Exchange event" do
      identifier = "TE-decision-invalid-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      Exchange.subscribe("ticket.#{identifier}.agent.decision.requested")

      response = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => %{}})

      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["message"] == "Decision request was rejected by the durable DecisionStore."
      assert error["reason"] =~ "blocking"
      refute_receive {:event, _}, 200
    end

    test "an issue with no identifier fails closed" do
      issue = %Issue{id: nil, identifier: nil}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("emit_event", %{"name" => "decision.requested", "message" => "Q?", "payload" => %{"blocking" => true}})

      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["message"] == "Decision requests require a ticket identifier."
      assert error["reason"] == "no_issue_identifier"
    end

    test "generic lookalikes of reserved Decision names fail cleanly, not with a crash" do
      identifier = "TE-decision-collision-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      executor = ToolExecutor.build(issue, nil, nil)

      for name <- [
            "custom.decision.requested",
            "custom.decision.acknowledged",
            "custom.decision.resolved"
          ] do
        response = executor.("emit_event", %{"name" => name, "message" => "Q?", "payload" => %{}})

        assert response["success"] == false
        assert Jason.decode!(response["output"])["error"]["reason"] =~ "decision_requires_durable_publish"
      end
    end

    test "a DecisionStore call timeout becomes a tool failure instead of exiting the agent turn" do
      identifier = "TE-decision-timeout-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      blocked_store = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(blocked_store, :stop) end)

      decision_requester = fn payload, opts ->
        Aiur.DecisionStore.request(payload, opts, blocked_store, 10)
      end

      executor =
        ToolExecutor.build(issue, nil, nil, %{}, decision_requester: decision_requester)

      response =
        executor.("emit_event", %{
          "name" => "decision.requested",
          "message" => "Q?",
          "payload" => %{"blocking" => true}
        })

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["reason"] =~ "timeout"
      assert Process.alive?(self())
    end
  end

  describe "decision lifecycle events route through Aiur.DecisionStore" do
    test "exact acknowledgement carries trusted ticket/session/invocation context" do
      identifier = "TE-decision-ack-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      parent = self()

      recorder = fn type, payload, opts ->
        send(parent, {:lifecycle_recorded, type, payload, opts})

        {:ok,
         %{
           decision_id: payload["decision_id"],
           version: 3,
           answered_version: payload["expected_version"],
           action_id: payload["action_id"],
           status: :accepted,
           decision_status: type
         }}
      end

      executor =
        ToolExecutor.build(
          issue,
          nil,
          nil,
          %{backend: "codex", thread_id: "thread-ack"},
          decision_lifecycle_recorder: recorder
        )

      response =
        ToolExecutor.execute(
          executor,
          "emit_event",
          %{
            "name" => "decision.acknowledged",
            "message" => "Applying it",
            "payload" => %{
              "decision_id" => "dec_123",
              "action_id" => "act_123",
              "expected_version" => 2,
              "actor" => %{"kind" => "operator", "id" => "attacker"}
            }
          },
          "call-ack-1"
        )

      assert response["success"] == true
      result = Jason.decode!(response["output"])["result"]
      assert result["status"] == "accepted"
      assert result["decision_status"] == "acknowledged"

      assert_receive {:lifecycle_recorded, :acknowledged, payload, opts}, 2_000
      assert payload["detail"] == "Applying it"
      assert opts[:ticket_identifier] == identifier
      assert opts[:actor].kind == :agent
      assert opts[:actor].id == "ticket-agent"
      refute opts[:actor].id =~ "attacker"
      assert opts[:source] == %{agent_id: "codex", session_id: "thread-ack", invocation_id: "call-ack-1"}
    end

    test "exact resolution is reserved while a generic decision slug stays generic" do
      identifier = "TE-decision-resolve-#{System.unique_integer([:positive])}"
      issue = %Issue{identifier: identifier}
      parent = self()

      recorder = fn type, payload, _opts ->
        send(parent, {:resolved_through_store, type})

        {:ok,
         %{
           decision_id: payload["decision_id"],
           version: 1,
           answered_version: 1,
           action_id: payload["action_id"],
           status: :duplicate,
           decision_status: :resolved
         }}
      end

      executor = ToolExecutor.build(issue, nil, nil, %{}, decision_lifecycle_recorder: recorder)

      resolution =
        executor.("emit_event", %{
          "name" => "decision.resolved",
          "message" => "Done",
          "payload" => %{"decision_id" => "dec_1", "action_id" => "act_1", "expected_version" => 1}
        })

      assert resolution["success"] == true
      assert_receive {:resolved_through_store, :resolved}, 2_000

      generic = executor.("emit_event", %{"name" => "decision.use-something", "message" => "ordinary"})
      assert generic["success"] == true
      refute_receive {:resolved_through_store, _}
    end

    test "lifecycle rejection is returned as a normal tool failure" do
      issue = %Issue{identifier: "TE-decision-lifecycle-reject"}
      recorder = fn _type, _payload, _opts -> {:error, {:conflict, :wrong_action}} end
      executor = ToolExecutor.build(issue, nil, nil, %{}, decision_lifecycle_recorder: recorder)

      response =
        executor.("emit_event", %{
          "name" => "decision.acknowledged",
          "message" => "Applying",
          "payload" => %{"decision_id" => "dec_1", "action_id" => "act_wrong", "expected_version" => 1}
        })

      assert response["success"] == false
      error = Jason.decode!(response["output"])["error"]
      assert error["message"] =~ "lifecycle"
      assert error["reason"] =~ "wrong_action"
    end
  end

  describe "subscriber closure" do
    test "missing topic pattern returns failure response" do
      issue = %Issue{id: "gid-te-08", identifier: "TE-08"}
      executor = ToolExecutor.build(issue, nil, nil)

      response = executor.("aiur_subscribe", %{"topic_pattern" => ""})

      assert response["success"] == false
    end
  end

  defp open_attentions(identifier) do
    case SubscriptionStore.snapshot(identifier) do
      :not_found -> []
      snapshot -> snapshot.open_attentions
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

  defp publication_recorder(workspace) do
    path = Path.join(workspace, "logs/event-publications.ndjson")
    fn record -> EventPublicationLog.write(workspace, record, path: path) end
  end

  defp publication_records(workspace) do
    workspace
    |> Path.join("logs/event-publications.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp wait_for_coordination_queue(name, key, attempts \\ 400)

  defp wait_for_coordination_queue(_name, _key, 0), do: :timeout

  defp wait_for_coordination_queue(name, key, attempts) do
    state = :sys.get_state(name)

    case Map.get(state.queues, key) do
      queue when not is_nil(queue) ->
        if :queue.is_empty(queue), do: retry_coordination_queue(name, key, attempts), else: :ok

      nil ->
        retry_coordination_queue(name, key, attempts)
    end
  end

  defp retry_coordination_queue(name, key, attempts) do
    receive do
    after
      5 -> wait_for_coordination_queue(name, key, attempts - 1)
    end
  end
end
