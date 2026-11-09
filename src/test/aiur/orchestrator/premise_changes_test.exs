Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.Orchestrator.PremiseChangesTest do
  use Aiur.DecisionStoreCase, async: false

  import ExUnit.CaptureLog

  alias Aiur.{DecisionAnswer, ExecutorWakeInbox, Issue}
  alias Aiur.Orchestrator.PremiseChanges

  @label "agent:premise-changed"

  defp issue(id, state, body), do: %Issue{id: id, identifier: id, state: state, description: body}

  defp flag(change, issues) do
    test_pid = self()

    PremiseChanges.flag(change,
      fetch_issues: fn -> {:ok, issues} end,
      add_label: fn id, label -> send(test_pid, {:label, id, label}) && :ok end,
      wake: &send(test_pid, {:wake, &1}),
      message_worker: fn id, text -> send(test_pid, {:message, id, text}) end,
      label: @label,
      terminal_states: ["done"]
    )
  end

  @d1 "dec_0123456789abcdef"
  @d2 "dec_fedcba9876543210"
  @actor %{kind: :operator, id: "dashboard"}
  @revised %{decision_id: @d1, kind: :revised, old_answer: struct(DecisionAnswer, selected_option_id: "B", actor: @actor), new_answer: struct(DecisionAnswer, selected_option_id: "C", actor: @actor)}

  test "a revised premise labels, wakes and messages only the tickets that list it" do
    issues = [
      issue("10", "todo", "Build the saver.\n\nPremises: #{@d1}, #{@d2}"),
      issue("11", "in-progress", "Premises: #{@d2}"),
      issue("12", "todo", "No premises here")
    ]

    assert flag(@revised, issues) == ["10"]
    assert_received {:label, "10", @label}
    refute_received {:label, "11", _}
    refute_received {:label, "12", _}

    assert_received {:wake, wake}
    assert wake["topic"] == "ticket.10.agent.attention.premise-changed"
    assert wake["decision_id"] == @d1
    assert {wake["previous"].selected_option_id, wake["answer"].selected_option_id} == {"B", "C"}

    assert_received {:message, "10", text}
    assert text =~ ~s(#{@d1} changed from "B" to "C")
  end

  test "a mooted premise carries the moot reason" do
    change = %{decision_id: @d1, kind: :mooted, old_answer: struct(DecisionAnswer, selected_option_id: "B"), moot_reason: "ticket_closed"}
    assert flag(change, [issue("10", "todo", "Premises: #{@d1}")]) == ["10"]
    assert_received {:wake, %{"premise_change" => "mooted", "previous" => %DecisionAnswer{selected_option_id: "B"}, "answer" => nil, "moot_reason" => "ticket_closed"}}
  end

  test "a multi-question answer reaches the worker as text, not JSON" do
    old = struct(DecisionAnswer, custom_response: ~s({"kind":"question_answers","question_answers":{"format":["B"],"size":["S","M"]}}))
    assert PremiseChanges.answer_text(old) == "format: B; size: S, M"
  end

  test "a closed dependent ticket is not relabelled" do
    assert flag(@revised, [issue("10", "done", "Premises: #{@d1}")]) == []
    refute_received {:label, _, _}
    refute_received {:wake, _}
  end

  test "a Premises line inside a code fence does not count" do
    assert PremiseChanges.premises("```\nPremises: #{@d1}\n```") == []
    assert PremiseChanges.premises("  premises: #{@d1} , #{@d2} ,") == [@d1, @d2]
  end

  test "a backticked id with trailing punctuation still counts" do
    assert PremiseChanges.premises("Premises: `#{@d1}`, `#{@d2}`.") == [@d1, @d2]
  end

  test "a token that is not a decision id is dropped with a warning" do
    log = capture_log(fn -> assert PremiseChanges.premises("Premises: dec_1, #{@d1}, save format B") == [@d1] end)
    assert log =~ ~s(ignoring Premises: token "dec_1")
    assert log =~ ~s(ignoring Premises: token "save format B")
  end

  test "two changed premises on one ticket stay two pending wakes" do
    root = Aiur.TestSupport.tmp_root!("aiur-premise-wakes")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)
    name = :"#{__MODULE__}.Inbox"

    start_supervised!(
      {ExecutorWakeInbox, name: name, debounce_ms: 60_000, path: Path.join(root, "wakes.ndjson"), cursor_path: Path.join(root, "cursor.json"), pending_path: Path.join(root, "pending.json")}
    )

    issues = [issue("10", "todo", "Premises: #{@d1}, #{@d2}")]
    wake = &ExecutorWakeInbox.enqueue_attention(&1, name)
    opts = [fetch_issues: fn -> {:ok, issues} end, add_label: fn _, _ -> :ok end, wake: wake, message_worker: fn _, _ -> :ok end, label: @label, terminal_states: []]

    PremiseChanges.flag(@revised, opts)

    PremiseChanges.flag(
      %{decision_id: @d2, kind: :mooted, old_answer: struct(DecisionAnswer, custom_response: ~s({"kind":"question_answers","question_answers":{"q1":["X"]}})), moot_reason: "obsolete"},
      opts
    )

    send(Process.whereis(name), :flush)
    _ = :sys.get_state(name)

    wakes =
      name
      |> ExecutorWakeInbox.pending()
      |> Enum.map(&{&1["ticket"], &1["decision_id"], &1["previous"]["option_id"], &1["previous"]["question_answers"], &1["option_id"], &1["moot_reason"]})
      |> Enum.sort()

    assert wakes == [{"10", @d1, "B", nil, "C", nil}, {"10", @d2, nil, %{"q1" => ["X"]}, nil, "obsolete"}]
  end

  describe "decision store" do
    setup %{dir: dir} do
      test_pid = self()
      pid = start_store!(dir, premise_notifier: &send(test_pid, {:premise_changed, &1}))

      {:ok, %{decision: decision}} =
        request(pid, %{
          "question" => "Which save format?",
          "blocking" => false,
          "options" => [%{"id" => "B", "label" => "B"}, %{"id" => "C", "label" => "C"}]
        })

      {:ok, %{decision: answered}} =
        answer(pid, decision.decision_id, %{"idempotency_key" => "a", "expected_version" => 1, "option_id" => "B"})

      %{pid: pid, decision: answered}
    end

    test "superseding an answer reports the old and new answer", %{pid: pid, decision: decision} do
      payload = %{expected_version: decision.version, option_id: "C", rationale: "changed", idempotency_key: "s"}
      assert {:ok, _} = DecisionStore.supersede(decision.decision_id, payload, [actor: %{kind: :operator, id: "dashboard"}], pid)

      id = decision.decision_id
      assert_received {:premise_changed, %{decision_id: ^id, kind: :revised, old_answer: %DecisionAnswer{selected_option_id: "B"}, new_answer: %DecisionAnswer{selected_option_id: "C"}}}
    end

    test "mooting an answer reports the old answer and reason", %{pid: pid, decision: decision} do
      assert {:ok, _} = DecisionStore.moot(decision.decision_id, %{"reason_class" => "ticket_closed"}, [actor: %{kind: :operator, id: "dashboard"}], pid)

      id = decision.decision_id
      assert_received {:premise_changed, %{decision_id: ^id, kind: :mooted, old_answer: %DecisionAnswer{selected_option_id: "B"}, moot_reason: "ticket_closed"}}
    end
  end
end
