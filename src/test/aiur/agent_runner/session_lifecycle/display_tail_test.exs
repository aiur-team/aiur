defmodule Aiur.AgentRunner.SessionLifecycle.DisplayTailTest do
  use ExUnit.Case, async: false

  alias Aiur.AgentEvents
  alias Aiur.AgentPubSub
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.Claude.DisplayTailer
  alias Aiur.Claude.HookEvents
  alias Aiur.Issue
  alias Aiur.LiveConversation
  alias Aiur.TrackerIdentity

  describe "should_display_tail?/3" do
    test "is true only for RC claude-repl sessions with an identifier" do
      assert SessionLifecycle.should_display_tail?("claude-repl", true, "101")

      refute SessionLifecycle.should_display_tail?("claude", true, "101")
      refute SessionLifecycle.should_display_tail?("codex", true, "101")
      refute SessionLifecycle.should_display_tail?("claude-repl", false, "101")
      refute SessionLifecycle.should_display_tail?("claude-repl", true, nil)
    end
  end

  describe "display_tailer_handler/3" do
    test "mirrors pane events through the Remote Control projection allowlist" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-rc-#{unique}", identifier: unique, tracker_identity: identity}
      opts = [telemetry_attempt_id: "attempt-#{unique}", session_id: "session-#{unique}", worker_generation: 5]

      source = %{
        identity: identity,
        attempt_id: "attempt-#{unique}",
        session_id: "session-#{unique}",
        backend: "claude-repl",
        worker_generation: 5
      }

      :ok = AgentPubSub.subscribe_agent(unique)

      handler = SessionLifecycle.display_tailer_handler(issue, "claude-repl", opts)

      remote =
        AgentEvents.transcript_event(:user, "Remote Control message",
          msg_id: "remote-#{unique}",
          payload: %{origin: :remote}
        )

      assistant = AgentEvents.transcript_event(:assistant, "Agent reply", msg_id: "assistant-#{unique}")

      assert :ok =
               handler.(%{
                 source_session_id: "session-#{unique}",
                 transcript_event: remote
               })

      assert :ok =
               handler.(%{
                 source_session_id: "session-#{unique}",
                 transcript_event: assistant
               })

      assert_receive {:transcript_event, ^remote}, 1000
      assert_receive {:transcript_event, ^assistant}, 1000

      assert %{messages: [%{role: "operator"}, %{role: "agent"}]} = LiveConversation.snapshot(source)
    end

    test "rotates exact transcript sources and projects tailer loss as stale" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-rc-rotate-#{unique}", identifier: unique, tracker_identity: identity}
      server = start_supervised!({LiveConversation, name: nil})

      opts = [
        telemetry_attempt_id: "attempt-#{unique}",
        worker_generation: 8,
        live_conversation_server: server,
        live_conversation_recipient: self(),
        live_conversation_authority: :display_tailer
      ]

      source = fn session_id ->
        %{
          identity: identity,
          attempt_id: "attempt-#{unique}",
          session_id: session_id,
          backend: "claude-repl",
          worker_generation: 8
        }
      end

      source_handler = SessionLifecycle.display_tailer_source_handler(issue, "claude-repl", opts)
      message_handler = SessionLifecycle.display_tailer_handler(issue, "claude-repl", opts)

      assert :ok = source_handler.({:available, nil, "transcript-a"})

      assistant_a =
        AgentEvents.transcript_event(:assistant, "session a", msg_id: "assistant-a-#{unique}")

      assert :ok =
               message_handler.(%{
                 source_session_id: "transcript-a",
                 transcript_event: assistant_a
               })

      assert %{state: :live, messages: [%{body: "session a"}]} =
               LiveConversation.snapshot(source.("transcript-a"), server: server)

      assert :ok = source_handler.({:available, "transcript-a", "transcript-b"})

      assert %{state: :ended, messages: [%{body: "session a"}]} =
               LiveConversation.snapshot(source.("transcript-a"), server: server)

      assert %{state: :known_empty, messages: []} =
               LiveConversation.snapshot(source.("transcript-b"), server: server)

      assistant_b =
        AgentEvents.transcript_event(:assistant, "session b", msg_id: "assistant-b-#{unique}")

      assert :ok =
               message_handler.(%{
                 source_session_id: "transcript-b",
                 transcript_event: assistant_b
               })

      assert :ok =
               MessageHandler.observe_operator_delivery(
                 issue,
                 %{id: 71, category: :operator_message, body: %{text: "accepted in session b"}},
                 "claude-repl",
                 Keyword.put(
                   opts,
                   :live_conversation_source_resolver,
                   fn -> "transcript-b" end
                 )
               )

      assert :ok =
               source_handler.({
                 :unavailable,
                 "transcript-b",
                 "transcript-b",
                 :inner_tailer_down
               })

      snapshot = LiveConversation.snapshot(source.("transcript-b"), server: server)
      assert snapshot.state == :stale
      assert snapshot.health == :unavailable
      assert snapshot.freshness == :stale
      assert Enum.map(snapshot.messages, & &1.body) == ["session b", "accepted in session b"]
    end

    test "ordinary provider callbacks cannot clear unavailable RC tailer health" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-rc-authority-#{unique}", identifier: unique, tracker_identity: identity}
      server = start_supervised!({LiveConversation, name: nil})

      opts = [
        attempt_id: "attempt-#{unique}",
        session_id: nil,
        worker_generation: 9,
        live_conversation_server: server,
        live_conversation_authority: :display_tailer
      ]

      source = %{
        identity: identity,
        attempt_id: "attempt-#{unique}",
        session_id: nil,
        backend: "claude-repl",
        worker_generation: 9
      }

      assert :ok = MessageHandler.mark_live_conversation_degraded(issue, "claude-repl", opts)

      ordinary_handler =
        MessageHandler.build(nil, issue, nil, nil, "claude-repl", nil, opts)

      assert :ok = ordinary_handler.(%{event: :agent_message, body: "ordinary duplicate"})

      assert %{state: :unavailable, health: :unavailable, messages: []} =
               LiveConversation.snapshot(source, server: server)

      assert {:error, {:live_conversation_context, :missing_source_session}} =
               MessageHandler.observe_operator_delivery(
                 issue,
                 %{id: 72, category: :operator_message, body: %{text: "not yet keyed"}},
                 "claude-repl",
                 opts
               )

      assert %{state: :unavailable, messages: []} =
               LiveConversation.snapshot(source, server: server)
    end

    test "composed RC attach keeps display backfill out of restart-unknown projection" do
      unique = Integer.to_string(System.unique_integer([:positive]))
      identity = tracker_identity(unique)
      issue = %Issue{id: "gid-#{unique}", identifier: unique, tracker_identity: identity}
      server = start_supervised!({LiveConversation, name: nil})
      session_id = "provider-session-#{unique}"

      opts = [
        telemetry_attempt_id: "attempt-#{unique}",
        worker_generation: 12,
        live_conversation_server: server,
        live_conversation_authority: :display_tailer
      ]

      source = %{
        identity: identity,
        attempt_id: "attempt-#{unique}",
        session_id: session_id,
        backend: "claude-repl",
        worker_generation: 12
      }

      path = Aiur.TestSupport.tmp_root!("session-lifecycle-display") <> ".jsonl"

      old_record = %{
        "uuid" => "old-record",
        "type" => "assistant",
        "timestamp" => "2026-07-17T12:00:00Z",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "pane-only history"}]
        }
      }

      on_exit(fn -> File.rm(path) end)
      :ok = AgentPubSub.subscribe_agent(unique)

      display_tailer =
        start_supervised!(
          {DisplayTailer,
           identifier: unique,
           on_message: SessionLifecycle.display_tailer_handler(issue, "claude-repl", opts),
           on_source: SessionLifecycle.display_tailer_source_handler(issue, "claude-repl", opts),
           interval_ms: nil}
        )

      source_event = %{
        "hook_event_name" => "PostToolUse",
        "transcript_path" => path,
        "session_id" => session_id
      }

      HookEvents.dispatch(unique, source_event)

      assert DisplayTailer.current_session(display_tailer) == session_id

      assert %{state: :unavailable, messages: []} =
               LiveConversation.snapshot(source, server: server)

      File.write!(path, Jason.encode!(old_record) <> "\n")
      HookEvents.dispatch(unique, source_event)

      assert DisplayTailer.current_session(display_tailer) == session_id
      assert {:ok, 1} = DisplayTailer.poll(display_tailer)
      assert_receive {:transcript_event, %{body: "pane-only history"}}, 1000

      assert %{state: :restart_unknown, messages: []} =
               LiveConversation.snapshot(source, server: server)

      live_record = %{
        "uuid" => "live-record",
        "type" => "assistant",
        "timestamp" => "2026-07-17T12:00:01Z",
        "message" => %{
          "content" => [%{"type" => "text", "text" => "new live evidence"}]
        }
      }

      File.write!(path, Jason.encode!(live_record) <> "\n", [:append])
      assert {:ok, 1} = DisplayTailer.poll(display_tailer)

      assert %{state: :restart_unknown, messages: [%{body: "new live evidence"}]} =
               LiveConversation.snapshot(source, server: server)
    end
  end

  defp tracker_identity(identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "provider-#{identifier}",
      identifier: identifier,
      reason: nil
    }
  end
end
