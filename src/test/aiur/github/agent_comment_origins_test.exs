defmodule Aiur.GitHub.AgentCommentOriginsTest do
  use ExUnit.Case, async: false

  alias Aiur.GitHub.AgentCommentOrigins

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-agent-comment-origins-#{System.unique_integer([:positive])}.json")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    Application.put_env(:aiur, :agent_comment_origins_path, path)

    on_exit(fn ->
      File.rm(path)

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end
    end)

    :ok
  end

  test "records exact verified comment IDs by ticket and reloads them from disk" do
    assert :ok = AgentCommentOrigins.record("42", %{"id" => 7001})
    assert AgentCommentOrigins.origin("42", %{"id" => 7001}) == :agent
    assert AgentCommentOrigins.origin("42", %{"id" => 7002}) == :external
    assert AgentCommentOrigins.origin("43", %{"id" => 7001}) == :external
  end

  test "uses stable decision state across a daemon restart" do
    decision_dir = Path.join(System.tmp_dir!(), "aiur-agent-comment-origins-state-#{System.unique_integer([:positive])}")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    previous_decision_dir = Application.get_env(:aiur, :decision_state_dir)

    Application.delete_env(:aiur, :agent_comment_origins_path)
    Application.put_env(:aiur, :decision_state_dir, decision_dir)

    on_exit(fn ->
      File.rm_rf(decision_dir)

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end

      if previous_decision_dir do
        Application.put_env(:aiur, :decision_state_dir, previous_decision_dir)
      else
        Application.delete_env(:aiur, :decision_state_dir)
      end
    end)

    assert {:ok, path} = AgentCommentOrigins.path_for()
    assert path == Path.join(decision_dir, "agent-comment-origins.json")
    assert :ok = AgentCommentOrigins.record("42", %{"id" => 7004})

    assert :agent =
             Task.async(fn -> AgentCommentOrigins.origin("42", %{"id" => 7004}) end)
             |> Task.await()
  end

  test "records a top-level PR conversation comment from gh output" do
    command = "gh pr comment 1153 --body 'Resolved the review.'"
    output = "https://github.com/its-everdred/aiur/pull/1153#issuecomment-7005\n"

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7005}) == :agent
  end

  test "records a PR conversation comment posted through gh api" do
    command = "gh api --method POST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved the review.'"
    output = ~s({"html_url":"https://github.com/its-everdred/aiur/pull/1153#issuecomment-7006"}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7006}) == :agent
  end

  test "records a gh api comment response that returns only its ID" do
    command = "gh api -XPOST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved the review.'"
    output = ~s({"id":7007}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7007}) == :agent
  end

  test "rejects a verified reply without a stable comment ID" do
    assert {:error, :missing_comment_id} = AgentCommentOrigins.record("42", %{})
  end

  test "serializes concurrent writes without dropping either ticket origin" do
    parent = self()

    start_record = fn ticket, comment_id ->
      Task.async(fn ->
        send(parent, {:record_task_ready, self()})

        receive do
          :record ->
            AgentCommentOrigins.record(ticket, %{"id" => comment_id},
              after_load: fn _ticket, _origins ->
                send(parent, {:origin_store_loaded, self()})

                receive do
                  :continue -> :ok
                end
              end
            )
        end
      end)
    end

    first = start_record.("42", 7001)
    second = start_record.("43", 7002)

    assert_receive {:record_task_ready, first_pid}
    assert_receive {:record_task_ready, second_pid}
    send(first_pid, :record)
    send(second_pid, :record)

    assert_receive {:origin_store_loaded, loaded_first}
    refute_receive {:origin_store_loaded, _other}, 100
    send(loaded_first, :continue)

    # `:global` retries a contended lock with randomized backoff. The first
    # writer has returned before this point, but the second may wait briefly
    # before it acquires the resource and reaches its test hook.
    assert_receive {:origin_store_loaded, loaded_second}, 2_000
    send(loaded_second, :continue)

    assert :ok = Task.await(first)
    assert :ok = Task.await(second)
    assert AgentCommentOrigins.origin("42", %{"id" => 7001}) == :agent
    assert AgentCommentOrigins.origin("43", %{"id" => 7002}) == :agent
  end

  test "waits for reply origin publication before classifying a visible comment" do
    parent = self()

    publisher =
      Task.async(fn ->
        AgentCommentOrigins.with_lock(fn ->
          send(parent, {:reply_visible, self()})

          receive do
            :publish_origin -> AgentCommentOrigins.record("42", %{"id" => 7003})
          end
        end)
      end)

    assert_receive {:reply_visible, publisher_pid}

    reader =
      Task.async(fn ->
        origin = AgentCommentOrigins.origin("42", %{"id" => 7003})
        send(parent, {:origin_classified, origin})
        origin
      end)

    refute_receive {:origin_classified, _origin}, 100
    send(publisher_pid, :publish_origin)

    assert :ok = Task.await(publisher)
    assert_receive {:origin_classified, :agent}, 2_000
    assert :agent = Task.await(reader)
  end
end
