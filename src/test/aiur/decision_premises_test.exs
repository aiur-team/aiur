Code.require_file("../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionPremisesTest do
  use Aiur.DecisionStoreCase, async: false

  alias Aiur.{DecisionPremises, Issue}

  @label "agent:premise-changed"

  defp issue(id, state, body), do: %Issue{id: id, identifier: id, state: state, description: body}

  defp flag(change, issues) do
    test_pid = self()

    DecisionPremises.flag(change,
      fetch_issues: fn -> {:ok, issues} end,
      add_label: fn id, label -> send(test_pid, {:label, id, label}) && :ok end,
      wake: &send(test_pid, {:wake, &1}),
      message_worker: fn id, text -> send(test_pid, {:message, id, text}) end,
      label: @label,
      terminal_states: ["done"]
    )
  end

  @revised %{decision_id: "dec_1", kind: :revised, old_answer: "B", new_answer: "C"}

  test "a revised premise labels, wakes and messages only the tickets that list it" do
    issues = [
      issue("10", "todo", "Build the saver.\n\nPremises: dec_1, dec_2"),
      issue("11", "in-progress", "Premises: dec_2"),
      issue("12", "todo", "No premises here")
    ]

    assert flag(@revised, issues) == ["10"]
    assert_received {:label, "10", @label}
    refute_received {:label, "11", _}
    refute_received {:label, "12", _}

    assert_received {:wake, wake}
    assert wake["topic"] == "ticket.10.agent.attention.premise-changed"
    assert wake["ticket"] == "10"
    assert {wake["decision_id"], wake["old_answer"], wake["new_answer"]} == {"dec_1", "B", "C"}

    assert_received {:message, "10", text}
    assert text =~ ~s(dec_1 changed from "B" to "C")
  end

  test "a mooted premise carries the moot reason" do
    change = %{decision_id: "dec_1", kind: :mooted, old_answer: "B", moot_reason: "ticket_closed"}
    assert flag(change, [issue("10", "todo", "Premises: dec_1")]) == ["10"]
    assert_received {:wake, %{"premise_change" => "mooted", "old_answer" => "B", "moot_reason" => "ticket_closed"}}
  end

  test "a closed dependent ticket is not relabelled" do
    assert flag(@revised, [issue("10", "done", "Premises: dec_1")]) == []
    refute_received {:label, _, _}
    refute_received {:wake, _}
  end

  test "a Premises line inside a code fence does not count" do
    assert DecisionPremises.premises("```\nPremises: dec_1\n```") == []
    assert DecisionPremises.premises("  premises: dec_1 , dec_2 ,") == ["dec_1", "dec_2"]
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
      assert_received {:premise_changed, %{decision_id: ^id, kind: :revised, old_answer: "B", new_answer: "C"}}
    end

    test "mooting an answer reports the old answer and reason", %{pid: pid, decision: decision} do
      assert {:ok, _} = DecisionStore.moot(decision.decision_id, %{"reason_class" => "ticket_closed"}, [actor: %{kind: :operator, id: "dashboard"}], pid)

      id = decision.decision_id
      assert_received {:premise_changed, %{decision_id: ^id, kind: :mooted, old_answer: "B", moot_reason: "ticket_closed"}}
    end
  end
end
