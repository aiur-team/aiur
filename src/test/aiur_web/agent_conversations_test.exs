defmodule AiurWeb.AgentConversationsTest do
  # A host app (Open Game Maker's editor and bug-report chats) starts a real
  # worker conversation with no ticket of its own; the Executor must hear about
  # it at once, and a retried start must not file a second ticket.
  use ExUnit.Case, async: true

  alias AiurWeb.AgentConversations

  setup do
    test = self()

    opts = [
      label_prefix: "agent",
      find_issue: fn marker, _opts ->
        send(test, {:find, marker})
        {:ok, Process.get(:existing)}
      end,
      create_issue: fn attrs, _opts ->
        send(test, {:create, attrs})
        {:ok, %{"number" => 1405, "url" => "https://github.com/o/r/issues/1405"}}
      end,
      notify: fn kind, text, notify_opts -> send(test, {:notify, kind, text, notify_opts}) end,
      publish: fn topic, payload, _opts -> send(test, {:publish, topic, payload}) end,
      refresh: fn -> send(test, :refresh) end
    ]

    {:ok, opts: opts}
  end

  test "files a conversation ticket that dispatches, and wakes the Executor at once", %{opts: opts} do
    params = %{"text" => "The jump arc clips on slopes", "owner" => "kevin", "path" => "games/blobs", "skills" => ["debugging"], "logs" => "trace", "complexity" => 2, "client_request_id" => "chat-1"}

    assert {:ok, started} = AgentConversations.start(params, opts)
    assert started == %{conversation_id: "chat-1", ticket: "1405", url: "https://github.com/o/r/issues/1405", created: true, thread: "/api/v1/1405/thread", messages: "/api/v1/1405/messages"}

    assert_received {:create, %{title: "Conversation: The jump arc clips on slopes", labels: ["agent:todo", "agent:conversation", "complexity:2"], body: body}}
    assert body =~ "<!-- aiur:agent-conversation:chat-1 -->"
    assert body =~ "`games/blobs`" and body =~ "`debugging`" and body =~ "started by `kevin`" and body =~ "```text\ntrace\n```"

    assert_received {:publish, "executor.agent_conversation.started", %{ticket: "1405", owner: "kevin", path: "games/blobs"}}
    assert_received {:notify, "info", "Agent conversation #1405 started by kevin: " <> _, [ticket: "1405", url: "https://github.com/o/r/issues/1405"]}
    assert_received :refresh
  end

  test "a retried start returns the first ticket without filing or announcing again", %{opts: opts} do
    Process.put(:existing, %{"number" => 1405, "url" => "https://github.com/o/r/issues/1405"})

    assert {:ok, %{ticket: "1405", created: false}} = AgentConversations.start(%{"text" => "again", "owner" => "kevin", "client_request_id" => "chat-1"}, opts)
    assert_received {:find, "<!-- aiur:agent-conversation:chat-1 -->"}
    refute_received {:create, _}
    refute_received {:publish, _, _}
    refute_received {:notify, _, _, _}
  end

  test "refuses requests that would file a bad ticket", %{opts: opts} do
    assert {:error, :blank_text} = AgentConversations.start(%{"text" => " ", "owner" => "kevin"}, opts)
    assert {:error, :invalid_owner} = AgentConversations.start(%{"text" => "x", "owner" => "kevin weaver"}, opts)
    assert {:error, :invalid_path} = AgentConversations.start(%{"text" => "x", "owner" => "kevin", "path" => "../secrets"}, opts)
    assert {:error, :invalid_path} = AgentConversations.start(%{"text" => "x", "owner" => "kevin", "path" => "/etc"}, opts)
    assert {:error, :invalid_skills} = AgentConversations.start(%{"text" => "x", "owner" => "kevin", "skills" => ["Bad Skill"]}, opts)
    assert {:error, :invalid_complexity} = AgentConversations.start(%{"text" => "x", "owner" => "kevin", "complexity" => 9}, opts)
    refute_received {:create, _}
  end

  test "a tracker failure files nothing and announces nothing", %{opts: opts} do
    opts = Keyword.put(opts, :create_issue, fn _attrs, _opts -> {:error, :rate_limited} end)

    assert {:error, {:tracker, :rate_limited}} = AgentConversations.start(%{"text" => "x", "owner" => "kevin"}, opts)
    refute_received {:publish, _, _}
    refute_received {:notify, _, _, _}
  end
end
