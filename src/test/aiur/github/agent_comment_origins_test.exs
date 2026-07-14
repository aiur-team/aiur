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

  test "rejects a verified reply without a stable comment ID" do
    assert {:error, :missing_comment_id} = AgentCommentOrigins.record("42", %{})
  end
end
