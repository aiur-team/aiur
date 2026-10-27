defmodule Aiur.DecisionStore.TestEnvAnswerCommentTest do
  # Guards #6579: a store started without :answer_comment_publisher must not start a
  # GitHub answer-comment task in the test environment. Such a task outlives its test
  # and logs publish_failed (or calls GitHub) inside an unrelated capture_log.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.DecisionStore

  test "answering with the test-env default publisher starts no answer-comment work" do
    dir = Aiur.TestSupport.tmp_root!("test-env-answer-comment-6579")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{question: "Proceed?", blocking: true, source_id: "guard-6579", authority: "supervisor_allowed", reversibility: "reversible", options: [%{id: "yes", label: "Proceed"}]},
        [ticket: %{identifier: "6579", title: "Guard", url: nil}, source: %{agent_id: "agent", session_id: "session"}],
        store
      )

    log =
      capture_log(fn ->
        assert {:ok, %{status: :accepted}} =
                 DecisionStore.answer(decision.decision_id, %{expected_version: 1, option_id: "yes", idempotency_key: "guard"}, [actor: %{kind: :operator, id: "guard"}], store)

        # The first publish attempt runs at once; a real publisher fails and logs within this window.
        Process.sleep(300)
      end)

    refute log =~ "aiur_decision_answer_comment"
  end
end
