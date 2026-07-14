defmodule Aiur.GitHub.AgentCommentOriginsTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentRunner.CommentContext
  alias Aiur.GitHub.AgentCommentOrigins
  alias Aiur.Issue

  setup do
    path = Path.join(System.tmp_dir!(), "aiur-agent-comment-origins-#{System.unique_integer([:positive])}.json")
    previous_path = Application.get_env(:aiur, :agent_comment_origins_path)
    previous_ttl = Application.get_env(:aiur, :agent_comment_origin_pending_ttl_ms)
    Application.put_env(:aiur, :agent_comment_origins_path, path)

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(path <> ".tickets")

      if previous_path do
        Application.put_env(:aiur, :agent_comment_origins_path, previous_path)
      else
        Application.delete_env(:aiur, :agent_comment_origins_path)
      end

      if previous_ttl do
        Application.put_env(:aiur, :agent_comment_origin_pending_ttl_ms, previous_ttl)
      else
        Application.delete_env(:aiur, :agent_comment_origin_pending_ttl_ms)
      end
    end)

    :ok
  end

  test "records exact verified comment IDs by ticket and reloads them from disk" do
    assert :ok = AgentCommentOrigins.record("42", %{"id" => 7001})
    assert AgentCommentOrigins.origin("42", %{"id" => 7001}) == {:ok, :agent}
    assert AgentCommentOrigins.origin("42", %{"id" => 7002}) == {:ok, :external}
    assert AgentCommentOrigins.origin("43", %{"id" => 7001}) == {:ok, :external}
  end

  test "filters an atom agent origin through the default comment-context resolver" do
    issue = %Issue{identifier: "42", id: "gid-42"}
    agent_comment = %{"id" => 7010, "body" => "agent reply", :authoritative => true}
    human_comment = %{"id" => 7011, "body" => "human follow-up", :authoritative => true}

    assert :ok = AgentCommentOrigins.record("42", agent_comment)

    fetchers = %{
      issue_comments: fn _ -> {:ok, [agent_comment, human_comment]} end,
      open_pr: fn _ -> {:ok, nil} end,
      pr_review_comments: fn _ -> {:ok, []} end,
      unaddressed_pr_review_thread_comments: fn _ -> {:ok, []} end
    }

    assert [%{id: 7011, comment_origin: "external"}] = CommentContext.events(issue, fetchers)
  end

  test "uses stable decision state across a daemon restart" do
    decision_dir =
      Path.join(
        System.tmp_dir!(),
        "aiur-agent-comment-origins-state-#{System.unique_integer([:positive])}"
      )

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

    assert {:ok, :agent} =
             Task.async(fn -> AgentCommentOrigins.origin("42", %{"id" => 7004}) end)
             |> Task.await()
  end

  test "records a top-level PR conversation comment from gh output" do
    command = "gh pr comment 1153 --body 'Resolved the review.'"
    output = "https://github.com/its-everdred/aiur/pull/1153#issuecomment-7005\n"

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7005}) == {:ok, :agent}
  end

  test "records a PR conversation comment posted through gh api" do
    command = "gh api --method POST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved the review.'"
    output = ~s({"html_url":"https://github.com/its-everdred/aiur/pull/1153#issuecomment-7006"}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7006}) == {:ok, :agent}
  end

  test "records a PR conversation comment posted through a quoted gh api path" do
    command = "gh api \"repos/its-everdred/aiur/issues/1153/comments\" --method POST -f body='Resolved the review.'"
    output = ~s({"id":70061}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 70_061}) == {:ok, :agent}
  end

  test "records a gh api comment response that returns only its ID" do
    command = "gh api -XPOST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved the review.'"
    output = ~s({"id":7007}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7007}) == {:ok, :agent}
  end

  test "records a gh api query response that returns only the exact comment ID" do
    command = "gh api -XPOST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved.' -q .id"

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, "7008\n", 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7008}) == {:ok, :agent}
  end

  test "uses only the top-level API mutation identity" do
    command = "gh api -XPOST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved.'"
    output = ~s({"id":7009,"user":{"id":7010}}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7009}) == {:ok, :agent}
    assert AgentCommentOrigins.origin("42", %{"id" => 7010}) == {:ok, :external}
  end

  test "uses a top-level JSON mutation ID before URLs nested in its response" do
    command = "gh api -XPOST repos/its-everdred/aiur/issues/1153/comments -f body='Resolved.'"

    output =
      ~s({"id":7012,"body":"prior https://github.com/owner/repo/pull/1#issuecomment-7013"}\n)

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7012}) == {:ok, :agent}
    assert AgentCommentOrigins.origin("42", %{"id" => 7013}) == {:ok, :external}
  end

  test "does not record unrelated commands and preserves a visible failed mutation" do
    assert :ignored =
             AgentCommentOrigins.record_gh_pr_comment(
               "42",
               "gh pr view 1153",
               "https://github.com/its-everdred/aiur/pull/1153#issuecomment-7008\n",
               0
             )

    assert :ok =
             AgentCommentOrigins.record_gh_pr_comment(
               "42",
               "gh pr comment 1153 --body 'Resolved the review.'",
               "https://github.com/its-everdred/aiur/pull/1153#issuecomment-7008\n",
               1
             )

    assert AgentCommentOrigins.origin("42", %{"id" => 7008}) == {:ok, :agent}
  end

  test "surfaces a successful PR comment response with no durable identity" do
    assert {:error, :gh_pr_comment_id_missing} =
             AgentCommentOrigins.record_gh_pr_comment(
               "42",
               "gh pr comment 1153 --body 'Resolved the review.'",
               "comment sent\n",
               0
             )
  end

  test "rejects compound public-comment commands before they can create ambiguous provenance" do
    command = "gh pr comment 1153 --body 'first' && gh pr comment 1153 --body 'second'"

    output =
      "https://github.com/owner/repo/pull/1153#issuecomment-7011\n" <>
        "https://github.com/owner/repo/pull/1153#issuecomment-7012\n"

    assert {:error, :unsupported_compound_public_comment_command} =
             AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)

    assert {:error, :unsupported_compound_public_comment_command} =
             AgentCommentOrigins.begin_gh_pr_comment("42", command, "compound-7011")
  end

  test "does not treat quoted review prose as a shell compound command" do
    command = "gh pr comment 1153 --body 'Use a | b; keep the existing behavior.'"
    output = "https://github.com/owner/repo/pull/1153#issuecomment-7014\n"

    assert :ok = AgentCommentOrigins.record_gh_pr_comment("42", command, output, 0)
    assert AgentCommentOrigins.origin("42", %{"id" => 7014}) == {:ok, :agent}
  end

  test "rejects public comments hidden behind shell wrappers" do
    for command <- [
          "cd src && gh pr comment 1153 --body 'Resolved.'",
          "env GH_HOST=github.com gh pr comment 1153 --body 'Resolved.'",
          "sh -c 'gh pr comment 1153 --body \\\"Resolved.\\\"'"
        ] do
      assert {:error, :unsupported_compound_public_comment_command} =
               AgentCommentOrigins.begin_gh_pr_comment("42", command, "wrapped-#{:erlang.phash2(command)}")

      assert {:error, :unsupported_compound_public_comment_command} =
               AgentCommentOrigins.record_gh_pr_comment("42", command, "7015\n", 0)
    end
  end

  test "rejects a verified reply without a stable comment ID" do
    assert {:error, :missing_comment_id} = AgentCommentOrigins.record("42", %{})
  end

  test "persists concurrent ticket writes without dropping either origin" do
    first = Task.async(fn -> AgentCommentOrigins.record("42", %{"id" => 7001}) end)
    second = Task.async(fn -> AgentCommentOrigins.record("43", %{"id" => 7002}) end)

    assert :ok = Task.await(first)
    assert :ok = Task.await(second)
    assert AgentCommentOrigins.origin("42", %{"id" => 7001}) == {:ok, :agent}
    assert AgentCommentOrigins.origin("43", %{"id" => 7002}) == {:ok, :agent}
  end

  test "defers classification while a public comment is pending" do
    assert :ok = AgentCommentOrigins.begin_gh_pr_comment("42", "gh pr comment 1153 --body 'Resolved.'", "pending-7003")

    assert {:error, {:pending_origin_recovery, ["pending-7003"]}} =
             AgentCommentOrigins.origin("42", %{"id" => 7003})

    assert :ok = AgentCommentOrigins.complete_review_thread_reply("42", "pending-7003", %{"id" => 7003})
    assert AgentCommentOrigins.origin("42", %{"id" => 7003}) == {:ok, :agent}
  end

  test "fails closed for corrupt durable state" do
    assert :ok = File.write(Application.fetch_env!(:aiur, :agent_comment_origins_path), "not json")

    assert {:error, {:store_read_failed, _reason}} =
             AgentCommentOrigins.origin("42", %{"id" => 7013})
  end

  test "fails closed for parseable durable state with invalid origins" do
    path = Application.fetch_env!(:aiur, :agent_comment_origins_path)
    assert :ok = File.write(path, ~s({"origins":{"42":"not-a-list"},"pending":{}}))

    assert {:error, :invalid_origins} = AgentCommentOrigins.origin("42", %{"id" => 7013})
  end

  test "fails closed for parseable durable state with an invalid pending operation" do
    path = Application.fetch_env!(:aiur, :agent_comment_origins_path)

    assert :ok =
             File.write(
               path,
               ~s({"origins":{},"pending":{"42":[{"operation_id":"bad","started_at_ms":"now"}]}})
             )

    assert {:error, :invalid_pending_operation} =
             AgentCommentOrigins.origin("42", %{"id" => 7013})
  end

  test "expires an abandoned pending operation before accepting a distinct human comment" do
    Application.put_env(:aiur, :agent_comment_origin_pending_ttl_ms, 1)

    assert :ok =
             AgentCommentOrigins.begin_gh_pr_comment(
               "42",
               "gh pr comment 1153 --body 'agent reply'",
               "abandoned-7014"
             )

    Process.sleep(2)

    assert AgentCommentOrigins.origin("42", %{"id" => 7015}) == {:ok, :external}
  end

  test "expires a future-dated pending operation rather than quarantining a ticket forever" do
    path = Application.fetch_env!(:aiur, :agent_comment_origins_path)
    far_future = 9_999_999_999_999

    state = %{
      "origins" => %{},
      "pending" => %{
        "42" => [
          %{
            "operation_id" => "future",
            "started_at_ms" => far_future,
            "kind" => "gh_pr_comment",
            "command" => "gh pr comment 1153 --body 'Resolved.'",
            "observed_ids" => []
          }
        ]
      }
    }

    assert :ok = File.write(path, Jason.encode!(state))

    assert AgentCommentOrigins.origin("42", %{"id" => 7015}) == {:ok, :external}
  end

  test "recovers a legacy pending operation after restart" do
    path = Application.fetch_env!(:aiur, :agent_comment_origins_path)
    assert :ok = File.write(path, ~s({"origins":{},"pending":{"42":["legacy-reply"]}}))

    assert AgentCommentOrigins.origin("42", %{"id" => 7016}) == {:ok, :external}
  end

  test "keeps a known published review reply agent-origin through a persistence failure and recovery" do
    operation_id = "review-failure-7017"
    assert :ok = AgentCommentOrigins.begin_review_thread_reply("42", operation_id)

    assert {:error, :disk_full} =
             AgentCommentOrigins.complete_review_thread_reply(
               "42",
               operation_id,
               %{"id" => 7017},
               fn _ticket, _comment -> {:error, :disk_full} end
             )

    assert AgentCommentOrigins.origin("42", %{"id" => 7017}) == {:ok, :agent}

    Application.put_env(:aiur, :agent_comment_origin_pending_ttl_ms, 1)
    Process.sleep(2)

    assert AgentCommentOrigins.origin("42", %{"id" => 7017}) == {:ok, :agent}
    assert AgentCommentOrigins.origin("42", %{"id" => 7018}) == {:ok, :external}
  end
end
