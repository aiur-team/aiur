Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Commands.SuggestedResponsesTest do
  use Aiur.DecisionStoreCase, async: false

  setup do
    previous = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("suggested-responses")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config")
    File.write!(path, "tracker: {kind: memory}\n")
    Aiur.Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      if is_nil(previous), do: Aiur.Workflow.clear_workflow_file_path(), else: Aiur.Workflow.set_workflow_file_path(previous)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    %{config_path: path}
  end

  defp payload, do: %{question: "Choose scope?", blocking: false, source_id: "suggestions", options: [%{id: "small", label: "Small"}]}

  defp alert_opts do
    test_pid = self()

    [
      alert_fun: fn topic, message, opts ->
        send(test_pid, {:warning, topic, message, opts})
        :ok
      end
    ]
  end

  test "one option is accepted by default and warns once across retries and restart", %{dir: dir} do
    pid = start_store!(dir)
    assert {:ok, %{status: :accepted, decision: d}} = request(pid, payload(), alert_opts())
    assert_received {:warning, "ticket.979.agent.decision.suggested-responses", message, opts}
    assert message == "Command #{d.decision_id}: too_few_options"
    assert opts[:severity] == :info
    assert opts[:needs_attention] == false
    assert opts[:exchange_payload] == %{decision_id: d.decision_id, suggested_response_reason: :too_few_options}
    assert opts[:dedup_key] == {:suggested_responses, d.decision_id}
    assert opts[:issue] == "979"
    refute message =~ d.question
    assert {:ok, %{status: :duplicate}} = request(pid, payload(), alert_opts())
    refute_received {:warning, _, _, _}

    version_two = Map.put(payload(), :version, 2)
    assert {:ok, %{status: :accepted, decision: revised}} = request(pid, version_two, alert_opts())
    assert revised.decision_id == d.decision_id
    assert revised.version == 2
    refute_received {:warning, _, _, _}
    GenServer.stop(pid)
    replayed = start_store!(dir)
    assert {:ok, %{status: :duplicate}} = request(replayed, version_two, alert_opts())
    refute_received {:warning, _, _, _}

    assert {:ok, %{status: :accepted, decision: restored}} = request(replayed, Map.put(payload(), :version, 3), alert_opts())
    assert restored.decision_id == d.decision_id
    assert restored.version == 3
    refute_received {:warning, _, _, _}
    GenServer.stop(replayed)
  end

  test "opt-in enforcement rejects before persistence but native and attention origins skip it", %{dir: dir, config_path: path} do
    File.write!(path, "tracker: {kind: memory}\ndecisions: {require_suggested_responses: true}\n")
    assert :ok = Aiur.WorkflowStore.force_reload()
    assert Aiur.Config.decisions_require_suggested_responses?()
    pid = start_store!(dir)
    assert {:error, {:decision_invalid, {:suggested_responses, :too_few_options}}} = request(pid, payload(), alert_opts())
    assert DecisionStore.list(pid) == []
    refute_received {:warning, _, _, _}

    for origin <- [:native_question, :attention] do
      raw = %{payload() | source_id: "#{origin}", question: "#{origin} question", options: Enum.map(1..4, &%{id: "o#{&1}", label: "Option #{&1}"})}
      assert {:ok, %{status: :accepted}} = request(pid, raw, [origin: origin] ++ alert_opts())
    end

    refute_received {:warning, _, _, _}
    GenServer.stop(pid)
  end

  test "question ingress validates before persistence and stores derived label with attribution", %{dir: dir} do
    pid = start_store!(dir)
    q = %{question_id: "scope", question: "Choose native scope", header: "Scope", options: [%{label: "Small"}, %{label: "Large"}]}
    assert {:error, {:decision_invalid, {:questions, :secret_not_storable}}} = request(pid, payload(), questions: [Map.put(q, :secret, true)])
    assert DecisionStore.list(pid) == []
    assert {:ok, %{decision: d}} = request(pid, payload(), questions: [q], origin: :native_question)
    assert d.short_label == "Scope"
    assert [%{options: [%{id: "q1-o1"}, %{id: "q1-o2"}]}] = d.questions
    GenServer.stop(pid)
    replayed = start_store!(dir)
    assert {:ok, restored} = DecisionStore.get(d.decision_id, replayed)
    assert restored.short_label == "Scope"
    assert restored.questions == d.questions
    GenServer.stop(replayed)
  end
end
