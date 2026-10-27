defmodule Aiur.DecisionStore.TestEnvAnswerCommentTest do
  # Guards #6579: a store started without :answer_comment_publisher must not start a
  # GitHub answer-comment task in the test environment. Such a task outlives its test
  # and logs publish_failed (or calls GitHub) inside an unrelated capture_log.
  use ExUnit.Case, async: false

  alias Aiur.DecisionStore

  test "answering with the test-env default publisher starts no answer-comment task" do
    dir = Aiur.TestSupport.tmp_root!("test-env-answer-comment-6579")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({DecisionStore, name: nil, state_dir: dir, filesystem_sync_fun: fn -> :ok end, dispatch_delay_ms: 60_000})

    {:ok, %{decision: decision}} =
      DecisionStore.request(
        %{question: "Proceed?", blocking: true, source_id: "guard-6579", authority: "supervisor_allowed", reversibility: "reversible", options: [%{id: "yes", label: "Proceed"}]},
        [ticket: %{identifier: "6579", title: "Guard", url: nil}, source: %{agent_id: "agent", session_id: "session"}],
        store
      )

    before = Task.Supervisor.children(Aiur.TaskSupervisor)

    assert {:ok, %{status: :accepted}} =
             DecisionStore.answer(decision.decision_id, %{expected_version: 1, option_id: "yes", idempotency_key: "guard"}, [actor: %{kind: :operator, id: "guard"}], store)

    # The store starts the task inside answer/4, so it is a child by the time answer returns.
    started = Task.Supervisor.children(Aiur.TaskSupervisor) -- before
    assert Enum.filter(started, &started_by_or_uninitialized?(&1, store)) == []
  end

  # A task that has not run yet has no $callers; count it rather than race its start.
  defp started_by_or_uninitialized?(pid, store) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> store in Keyword.get(dictionary, :"$callers", [store])
      nil -> false
    end
  end
end
