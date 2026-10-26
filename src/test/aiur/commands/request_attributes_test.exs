Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.RequestAttributesTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.Commands.Requester

  defmodule FileOps do
    def write(fd, line) do
      if Jason.decode!(line)["event_type"] == "request_attributed",
        do: :file.write(fd, "corrupt\n"),
        else: :file.write(fd, line)
    end

    def sync(_fd), do: {:error, :timeout}
  end

  defp attrs do
    [
      requester: %{kind: :executor, executor_id: "operator", session_ref: "session-1"},
      origin: :executor_cli,
      native: %{harness: :codex, native_ref: "req-1", hold: :in_band},
      questions: [%{"id" => "q1"}]
    ]
  end

  defp records(dir) do
    dir |> Path.join("decisions.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "request attributes append after requested at the request version and replay on restart", %{dir: dir} do
    test_pid = self()

    pid =
      start_store!(dir,
        executor_request_publisher: fn d ->
          send(test_pid, {:published, d})
          {:ok, 1, 0}
        end
      )

    opts = Keyword.put(attrs(), :ticket, %{identifier: "executor"})
    assert {:ok, %{status: :accepted, decision: decision}} = request(pid, %{question: "Choose scope?", blocking: false, source_id: "attributed"}, opts)
    assert [requested, attributed] = records(dir)
    assert requested["event_type"] == "requested"
    assert attributed["event_type"] == "request_attributed"
    assert attributed["decision_version"] == 1
    assert requested["decision_version"] == attributed["decision_version"]
    assert decision.requester.kind == :executor
    assert decision.origin == :executor_cli
    assert decision.native.native_ref == "req-1"
    assert decision.questions == [%{"id" => "q1"}]
    assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
    assert_received {:published, ^decision}
    refute_received {:published, _other}
    GenServer.stop(pid)
    replayed = start_store!(dir)
    assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, replayed)
    assert DecisionStore.health(replayed) == :writable
    GenServer.stop(replayed)
  end

  test "requested snapshot bytes and hashes match the same request without attributes", %{dir: dir} do
    payload = %{question: "Choose scope?", blocking: false, source_id: "same"}
    now = DateTime.utc_now()
    pid = start_store!(dir)
    assert {:ok, %{decision: decision}} = request(pid, payload, Keyword.put(attrs(), :now, now))
    assert [requested, _attributed] = records(dir)
    {:ok, plain} = DecisionValidation.normalize(payload, ticket: @ticket, source: @source, now: now)

    {:ok, baseline} =
      DecisionEvent.new(:requested, plain.decision_id, 1, plain, event_id: elem(DecisionEvent.parse_provenance_event_id(requested["event_id"]), 1), run_id: requested["run_id"], now: now)

    assert Jason.encode!(requested) == Jason.encode!(DecisionEvent.to_json_safe(baseline))
    assert decision.content_hash == plain.content_hash
    refute Map.has_key?(requested["data"], "requester")
    GenServer.stop(pid)
  end

  test "trusted attention opts reach attribution and empty opts keep the single v1 event", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, %{decision: plain}} = request(pid, %{question: "Plain request?", blocking: false, requester: %{kind: :executor}, origin: :executor_cli})
    assert Requester.kind(plain) == :worker
    assert [requested] = records(dir)
    assert requested["event_type"] == "requested"
    assert {:ok, %{decision: attention}} = project_attention(pid, minimal_attention(), requester: %{kind: :worker, ticket: "979"}, origin: :attention)
    assert attention.requester.kind == :worker
    assert attention.origin == :attention
    assert Enum.map(records(dir), & &1["event_type"]) == ["requested", "requested", "request_attributed"]
    GenServer.stop(pid)
  end

  test "failed attribute reservation accepts the Command with defaults and logs the failure", %{dir: dir} do
    pid = start_store!(dir, event_id_reserver: fn -> {:error, :not_durable} end)

    log =
      capture_log(fn ->
        assert {:ok, %{status: :accepted, decision: decision}} = request(pid, %{question: "Choose scope?", blocking: false}, attrs())
        assert Requester.kind(decision) == :worker
        assert decision.requester == nil
        assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
      end)

    assert log =~ "phase=request_attribute_append_failed"
    assert length(records(dir)) == 1
    assert DecisionStore.health(pid) == :writable
    GenServer.stop(pid)
  end

  test "ambiguous attribution append holds writes while preserving the accepted Command", %{dir: dir} do
    pid = start_store!(dir, file_ops: FileOps, event_id_reserver: fn -> {:ok, "attribute-ambiguous"} end)
    assert {:ok, %{decision: decision}} = request(pid, %{question: "Choose scope?", blocking: false}, attrs())
    assert {:journal_ambiguous, "attribute-ambiguous" = event_id, _reason} = DecisionStore.health(pid)
    assert {:ok, ^decision} = DecisionStore.get(decision.decision_id, pid)
    assert {:error, {:store_unavailable, {:journal_ambiguous, ^event_id, _}}} = request(pid, %{question: "Next?", blocking: false})
    GenServer.stop(pid)
  end

  test "stale projection replays attribution before publishing the single requested notification", %{dir: dir} do
    test_pid = self()

    publisher = fn d ->
      send(test_pid, {:published, d})
      {:ok, 1, 0}
    end

    pid = start_store!(dir, executor_request_publisher: publisher)
    :sys.replace_state(pid, &%{&1 | projection_path: dir})

    capture_log(fn ->
      assert {:ok, %{decision: decision}} = request(pid, %{question: "Choose scope?", blocking: false}, attrs())
      assert decision.requester.kind == :executor
      assert {:projection_stale, %DateTime{}} = DecisionStore.health(pid)
    end)

    refute_received {:published, _decision}
    GenServer.stop(pid)
    replayed = start_store!(dir, executor_request_publisher: publisher)
    assert_received {:published, decision}
    assert decision.requester.kind == :executor
    assert decision.origin == :executor_cli
    refute_received {:published, _decision}
    assert DecisionStore.health(replayed) == :writable
    GenServer.stop(replayed)
  end

  test "executor sentinel is reserved at ingress but trusted executor requests and replay are accepted" do
    payload = %{question: "Choose scope?", blocking: false}
    assert {:error, {:decision_invalid, {:ticket_identifier, :reserved}}} = DecisionValidation.normalize(payload, ticket: %{identifier: " executor "})
    assert {:error, {:decision_invalid, {:ticket_identifier, :reserved}}} = DecisionValidation.normalize(payload, ticket: %{identifier: "executor"}, requester: %{kind: :worker})
    assert {:ok, _decision} = DecisionValidation.normalize(payload, ticket: %{identifier: "executor"}, requester: %{kind: :executor})
  end

  test "old nonblocking Executor Command is exempt from expiry", %{dir: dir} do
    now = DateTime.utc_now()
    pid = start_store!(dir)
    assert {:ok, %{decision: executor}} = request(pid, %{question: "Choose scope?", blocking: false}, attrs() ++ [now: DateTime.add(now, -600, :second)])

    assert {:ok, 0} =
             DecisionExpiry.sweep(
               now: now,
               active_identifiers_fun: fn -> {:ok, []} end,
               decisions_fun: fn -> {:ok, [executor]} end,
               expire_fun: fn _, _, _ -> flunk("Executor request must not expire") end,
               attention_reconcile_fun: fn _, _, _, _ -> :ok end
             )

    GenServer.stop(pid)
  end
end
