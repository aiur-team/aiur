defmodule Aiur.BrowserHarness.ConversationFixture do
  @moduledoc false
  use Phoenix.Controller, formats: []
  alias Aiur.BrowserHarness.Fixtures
  alias Aiur.Conversation.{Ingest, Ref}

  def reset(conn, _params) do
    # Stop the cached writer before replacing its on-disk head and sessions.
    id = Ref.conversation_id(Ref.executor())

    for {pid, _} <- Registry.lookup(Aiur.Conversation.Registry, id) do
      :ok = DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, pid)
    end

    Fixtures.conversation(Application.fetch_env!(:aiur, :conversation_state_dir))
    Plug.Conn.send_resp(conn, 200, "reset")
  end

  def append(conn, _params) do
    ref = Ref.executor()
    source = %{harness: "codex", role: :executor, provider_session_id: "browser", aiur_attempt_id: nil, transcript_source: %{kind: :file, locator_hash: nil}, start_reason: :start}
    events = Enum.map(1..3, &%{role: "assistant", msg_id: "browser-#{System.unique_integer([:positive])}-#{&1}", body: "Live browser entry", timestamp: DateTime.utc_now()})
    Ingest.append(ref, source, events)
    {:ok, writer} = Ingest.writer(ref)
    :ok = GenServer.call(writer, :flush)
    Plug.Conn.send_resp(conn, 200, "appended")
  end
end
