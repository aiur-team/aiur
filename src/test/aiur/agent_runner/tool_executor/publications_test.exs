defmodule Aiur.AgentRunner.ToolExecutor.PublicationsTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.{EventPublicationLog, Issue, TrackerIdentity}
  alias Aiur.Events.Exchange

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
      workspace = Aiur.TestSupport.tmp_root!("aiur-publication")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

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
      workspace = Aiur.TestSupport.tmp_root!("aiur-publication")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

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
        workspace = Aiur.TestSupport.tmp_root!("aiur-publication")
        on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

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
      workspace = Aiur.TestSupport.tmp_root!("aiur-publication")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

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
      workspace = Aiur.TestSupport.tmp_root!("aiur-publication")
      on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

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
  end

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
end
