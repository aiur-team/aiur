defmodule Aiur.OperatorAnswerCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Aiur.OperatorAnswerCLI

  test "routes an explicit operator answer for a human-required Command" do
    test_pid = self()
    decision = %{decision_id: "dec-human", authority: :human_required, version: 7}

    output =
      capture_io(fn ->
        assert OperatorAnswerCLI.answer(
                 decision_id: decision.decision_id,
                 option_id: "build_content",
                 operator: true,
                 expected_version: 7,
                 confirmation: "dec-human",
                 operator_name_fun: fn -> "operator-1" end,
                 decision_store: :decision_store,
                 get_fun: fn "dec-human", :decision_store -> {:ok, %{decision: decision}} end,
                 answer_fun: fn id, payload, opts, store ->
                   send(test_pid, {:answer, id, payload, opts, store})
                   {:ok, %{status: :accepted}}
                 end
               ) == 0
      end)

    assert_received {:answer, "dec-human", payload, [actor: %{kind: :operator, id: "cli:operator-1"}], :decision_store}
    assert payload["expected_version"] == 7
    assert payload["option_id"] == "build_content"
    assert String.starts_with?(payload["idempotency_key"], "cli_")
    assert output =~ "operator cli:operator-1 answered Command dec-human"
  end

  test "requires the explicit operator flag" do
    assert capture_io(:stderr, fn ->
             assert OperatorAnswerCLI.answer(decision_id: "dec-human", option_id: "ship") == 64
           end) =~ "answer requires --operator"
  end

  test "refuses commands that are not human-required" do
    assert capture_io(:stderr, fn ->
             assert OperatorAnswerCLI.answer(
                      decision_id: "dec-delegated",
                      option_id: "ship",
                      operator: true,
                      expected_version: 1,
                      confirmation: "dec-delegated",
                      get_fun: fn _, _ -> {:ok, %{decision: %{authority: :supervisor_allowed}}} end,
                      answer_fun: fn _, _, _, _ -> flunk("must not record a delegated command") end
                    ) == 1
           end) =~ "not_human_required"
  end

  test "rejects a stale preview version and a mismatched confirmation before recording" do
    decision = %{decision_id: "dec-human", authority: :human_required, version: 8}

    output =
      capture_io(:stderr, fn ->
        assert OperatorAnswerCLI.answer(
                 decision_id: "dec-human",
                 option_id: "build_content",
                 operator: true,
                 expected_version: 7,
                 confirmation: "wrong-id",
                 get_fun: fn _, _ -> {:ok, %{decision: decision}} end,
                 answer_fun: fn _, _, _, _ -> flunk("stale or unconfirmed answer must not be recorded") end
               ) == 1
      end)

    assert output =~ "version_changed"

    output =
      capture_io(:stderr, fn ->
        assert OperatorAnswerCLI.answer(
                 decision_id: "dec-human",
                 option_id: "build_content",
                 operator: true,
                 expected_version: 8,
                 confirmation: "wrong-id",
                 get_fun: fn _, _ -> {:ok, %{decision: decision}} end,
                 answer_fun: fn _, _, _, _ -> flunk("mismatched confirmation must not be recorded") end
               ) == 64
      end)

    assert output =~ "confirmation did not match"
  end
end
