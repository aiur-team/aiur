defmodule Aiur.VoiceConverse.Host.HistoryIntegrationTest do
  use ExUnit.Case, async: false

  alias Aiur.Conversation.{Entry, Ref, Session, Store}
  alias Aiur.TrackerIdentity
  alias Aiur.VoiceConverse.Host.{BriefingSource, Worker}

  test "worker details read the real journal by identity and mark a bounded tail incomplete" do
    root = Aiur.TestSupport.tmp_root!("voice-worker-history")
    previous = Application.fetch_env(:aiur, :conversation_state_dir)
    Application.put_env(:aiur, :conversation_state_dir, root)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :conversation_state_dir, value)
        :error -> Application.delete_env(:aiur, :conversation_state_dir)
      end

      Aiur.TestCleanup.rm_rf!(root)
    end)

    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_voice", "number" => 42}, {"org", "repo"}, {"org", "repo"})
    {:ok, ref} = Ref.worker(identity)
    dir = Path.join(root, Ref.conversation_id(ref))
    now = DateTime.utc_now()
    {:ok, head} = Store.prepare(dir, ref)
    session = %Session{session_seq: 1, harness: "codex", provider_session_id: "voice-test", first_pos: 1, started_at: now, start_reason: "start"}
    assert :ok = Store.append_session_line(dir, Session.start_line(session))
    entries = for pos <- 1..2, do: Entry.to_json(%Entry{pos: pos, kind: "message", role: "agent", session_seq: 1, observed_at: now, body: "message #{pos}"})
    assert {:ok, _head} = Store.append_entries(dir, head, entries)
    assert {:ok, text} = BriefingSource.details(%Worker{identity: identity}, "conversation", n: 1)
    assert text == "Conversation source: journal; complete: false.\nagent: message 2"
  end
end
