Code.require_file("../../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ConversationFirstEntryTest do
  use Aiur.TestSupport.BuildHome.ProtocolCase
  import Aiur.TestSupport.BuildHome.ProtocolCase, except: [source: 1]
  import Aiur.Conversation.TestSupport
  alias Aiur.Conversation.{History, Ingest, Ref, TestSupport}

  setup context, do: TestSupport.setup(context)

  test "an unrecorded worker receives its first message without reloading" do
    identity = %Aiur.TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "acme",
      repository: "aiur",
      provider_id: "NODE-1110",
      database_id: 1110,
      identifier: "1110",
      reason: nil
    }

    {:ok, ref} = Ref.worker(identity)
    assert {:error, :not_found} = History.snapshot(ref)
    {:ok, view, html} = live(build_conn(), "/conversations/#{Ref.conversation_id(ref)}")
    assert html =~ "No messages yet"
    assert has_element?(view, "[data-state=not_found]")

    Ingest.append(ref, %{source() | role: :worker}, [event(1)])
    assert :ok = flush(ref)
    assert has_element?(view, "#entry-1", "message 1")
    refute render(view) =~ "No messages yet"
    assert has_element?(view, "[data-state=live]")
  end

  # Existing behavior: malformed ids must not subscribe when pre-record links are added.
  test "future regression guard: invalid subscription ids remain not found" do
    assert History.subscribe("conv_bad") == {:error, :not_found}
  end
end
