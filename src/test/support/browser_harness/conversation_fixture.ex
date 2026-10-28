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

    root = Application.fetch_env!(:aiur, :conversation_state_dir)
    Fixtures.conversation(root)

    anchors = [
      %{
        "event" => %{"event_id" => 1, "observed_at" => DateTime.to_iso8601(DateTime.utc_now())},
        "kind" => "pr_merged",
        "conversation_id" => id,
        "pos" => 1000,
        "placement" => "at",
        "precision" => "causal",
        "label" => "PR #42 merged"
      },
      %{
        "event" => %{"event_id" => 2, "observed_at" => DateTime.to_iso8601(DateTime.utc_now())},
        "kind" => "command_requested",
        "conversation_id" => id,
        "pos" => 1100,
        "placement" => "at",
        "precision" => "exact",
        "label" => "Command requested",
        "subject_ref" => %{"decision_id" => "fixture-command"}
      }
    ]

    File.write!(Path.join([root, id, "anchors.jsonl"]), Enum.map(anchors, &(Jason.encode!(Map.put(&1, "anchor_id", "fixture-#{&1["event"]["event_id"]}")) <> "\n")))
    Plug.Conn.send_resp(conn, 200, "reset")
  end

  def append(conn, %{"command_id" => decision_id}) do
    ref = Ref.executor()

    anchor = %{
      "v" => 1,
      "anchor_id" => "fixture-command-#{decision_id}",
      "event" => %{"event_id" => 3, "observed_at" => DateTime.to_iso8601(DateTime.utc_now())},
      "kind" => "command_requested",
      "conversation_id" => Ref.conversation_id(ref),
      "pos" => 1100,
      "placement" => "at",
      "precision" => "exact",
      "label" => "Command requested",
      "subject_ref" => %{"decision_id" => decision_id}
    }

    Ingest.anchor(ref, anchor)
    {:ok, writer} = Ingest.writer(ref)
    :ok = GenServer.call(writer, :flush)
    # The writer casts the durable anchor before the read-side lookup below.
    {:ok, _} = Aiur.Conversation.History.command_anchor(decision_id)
    Plug.Conn.send_resp(conn, 200, "anchored")
  end

  def append(conn, %{"kinds" => "true"}) do
    append_events(conn, kinds(), true)
  end

  def append(conn, _params) do
    events = Enum.map(1..3, &%{role: "assistant", msg_id: "browser-#{System.unique_integer([:positive])}-#{&1}", body: "Live browser entry", timestamp: DateTime.utc_now()})
    append_events(conn, events)
  end

  defp append_events(conn, events, gap? \\ false) do
    ref = Ref.executor()
    source = %{harness: "codex", role: :executor, provider_session_id: "browser", aiur_attempt_id: nil, transcript_source: %{kind: :file, locator_hash: nil}, start_reason: :start}
    Ingest.append(ref, source, events)
    if gap?, do: Ingest.gap(ref, :backpressure, DateTime.utc_now(), DateTime.utc_now())
    {:ok, writer} = Ingest.writer(ref)
    :ok = GenServer.call(writer, :flush)
    Plug.Conn.send_resp(conn, 200, "appended")
  end

  defp kinds do
    long = String.duplicate("x", 400)

    [
      %{role: "assistant", body: "**Agent prose** " <> long},
      %{role: "reasoning", body: "Reasoning " <> long},
      %{role: "command", payload: %{command: "git status", output: long, exit_code: 2}},
      %{role: "tool", body: "Search", payload: %{tool: "search", success: true, output: long}},
      %{role: "tool", payload: %{tool: "edit", title: "file.ex", output: "@@ hunk\n+added\n-removed\n" <> long}},
      %{role: "user", body: "Operator " <> long},
      %{role: "system", body: "System " <> long},
      %{role: "alert", body: "Check recording"}
    ]
    |> Enum.map(&Map.merge(&1, %{msg_id: "kinds-#{System.unique_integer([:positive])}", timestamp: DateTime.utc_now()}))
  end
end
