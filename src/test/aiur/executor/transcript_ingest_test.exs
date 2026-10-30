Code.require_file("../conversation/journal_support.exs", __DIR__)

defmodule Aiur.Executor.TranscriptIngestTest do
  use ExUnit.Case, async: false
  import Aiur.Conversation.TestSupport, only: [flush: 1, rows: 1, sessions: 1]
  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{Session, TranscriptIngest}

  setup context do
    context = TestSupport.setup(context)
    old = Application.fetch_env(:aiur, :executor_state_dir)
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end
    end)

    start_supervised!({Session, instance_key: "transcript-test"})
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    Map.merge(context, %{tail_supervisor: sup, home: context.root})
  end

  test "boot backfills all record kinds with provenance and remote-control origin", context do
    path = bind(context, "one", fixture())
    start_ingest(context)
    assert :ok = TranscriptIngest.poll()
    assert :ok = flush(context.ref)
    entries = rows(context.dir)

    assert Enum.map(entries, &{&1["kind"], &1["body"]}) == [
             {"message", "answer"},
             {"reasoning", "thought"},
             {"command", "pwd"},
             {"operator_message", "prompt"},
             {"tool_result", "tool result"},
             {"operator_message", "phone"}
           ]

    assert Enum.at(entries, 4)["output"] == "/repo"
    assert Enum.at(entries, 5)["meta"]["origin"] == "remote_control"
    assert Enum.at(entries, 3)["role"] == "executor_operator"
    assert [session] = sessions(context.dir)
    assert session["harness"] == "claude"
    assert session["transcript_source"] == %{"kind" => "provider_file", "locator_hash" => hash(path)}
    assert {:ok, binding} = Session.current()
    assert binding.transcript_offset == File.stat!(path).size
  end

  test "restart resumes the saved cursor, replays uncheckpointed overlap without duplicates, and keeps partial lines", context do
    path = bind(context, "one", [assistant("first", "first")])
    start_ingest(context)
    TranscriptIngest.poll()
    assert {:ok, first} = Session.current()
    assert first.transcript_offset == File.stat!(path).size
    append(path, [assistant("second", "second")])
    TranscriptIngest.poll()
    assert {:ok, second} = Session.current()
    assert second.transcript_offset == first.transcript_offset
    # Simulate a daemon crash after journal fsync and before the next offset checkpoint.
    assert :ok = flush(context.ref)
    stop_supervised!(TranscriptIngest)
    # Shutdown checkpoints; overwrite with the older durable receipt to model a hard crash.
    assert {:ok, _} = Session.record_offset(first.binding_id, first.transcript_offset)
    stop_supervised!(Session)
    start_supervised!({Session, instance_key: "transcript-test"})
    {:ok, writer} = Aiur.Conversation.Ingest.writer(context.ref)
    DynamicSupervisor.terminate_child(Aiur.Conversation.JournalSupervisor, writer)
    Application.put_env(:aiur, :conversation_journal, Keyword.put(Application.fetch_env!(:aiur, :conversation_journal), :run_id, "run-two"))
    # A record before the stored cursor is deliberately changed to a new UUID;
    # dedup alone cannot hide an incorrect replay from zero.
    File.write!(path, String.replace(File.read!(path), "first", "ghost"))
    append(path, [assistant("third", "third")])
    partial = Jason.encode!(assistant("fourth", "fourth"))
    File.write!(path, partial, [:append])
    start_ingest(context)
    TranscriptIngest.poll()
    assert :ok = flush(context.ref)
    assert Enum.map(rows(context.dir), & &1["body"]) == ["first", "second", "third"]
    File.write!(path, "\n", [:append])
    TranscriptIngest.poll()
    assert :ok = flush(context.ref)
    assert Enum.map(rows(context.dir), & &1["body"]) == ["first", "second", "third", "fourth"]
  end

  test "clear retargets to a new file and detach drains without reopening a session", context do
    path = bind(context, "one", [assistant("first", "first")])
    start_ingest(context)
    TranscriptIngest.poll()
    assert {:ok, binding} = Session.current()
    assert {:ok, _} = Session.prepare_clear_rebind(binding.binding_id, %{event: "SessionEnd", reason: "clear", harness: "claude", session_id: "one", pid: "123"})
    next_path = transcript(context, "two", [assistant("second", "second")])
    assert {:ok, _} = Session.rebind_on_session_start(binding.binding_id, %{session_id: "two", harness: "claude", transcript_path: next_path, pid: "123", source: "clear"})
    TranscriptIngest.poll()
    TranscriptIngest.poll()
    append(next_path, [assistant("last", "last")])
    assert {:ok, _} = Session.detach(binding.binding_id, "stopped")
    TranscriptIngest.poll()
    assert :ok = flush(context.ref)
    assert Enum.map(rows(context.dir), & &1["body"]) == ["first", "second", "last"]

    assert Enum.map(sessions(context.dir), &{&1["type"], &1["start_reason"], &1["end_reason"]}) == [
             {"start", "start", nil},
             {"end", nil, "clear"},
             {"start", "clear", nil},
             {"end", nil, "stopped"}
           ]

    assert DynamicSupervisor.count_children(context.tail_supervisor).active == 0
    assert File.exists?(path)
  end

  test "truncation supersedes the old session and starts a fork", context do
    path = bind(context, "one", [assistant("old", String.duplicate("long", 100))])
    start_ingest(context)
    TranscriptIngest.poll()
    File.write!(path, encode([assistant("new", "new")]))
    TranscriptIngest.poll()
    assert :ok = flush(context.ref)
    assert Enum.map(rows(context.dir), & &1["body"]) == [String.duplicate("long", 100), "new"]

    assert Enum.map(sessions(context.dir), &{&1["type"], &1["start_reason"], &1["end_reason"]}) == [
             {"start", "start", nil},
             {"end", nil, "superseded"},
             {"start", "fork", nil}
           ]
  end

  test "boot rejects a stored path replaced with a symlink and exposes its rejection", context do
    path = bind(context, "one", [assistant("private", "private")])
    target = transcript(context, "other", [assistant("secret", "secret")])
    File.rm!(path)
    File.ln_s!(target, path)
    start_ingest(context)
    TranscriptIngest.poll()
    assert DynamicSupervisor.count_children(context.tail_supervisor).active == 0
    assert TranscriptIngest.status() == %{transcript_rejection: :not_regular}
    assert :ok = flush(context.ref)
    assert [gap] = rows(context.dir)
    assert {gap["kind"], gap["meta"]["reason"]} == {"gap", "source_unreadable"}
  end

  test "unattached, nil-path and foreign hooks never start capture", context do
    start_ingest(context)
    path = transcript(context, "foreign", [assistant("secret", "secret")])
    Phoenix.PubSub.broadcast(context.pubsub, "executor_hook", {:executor_hook, %{harness: "claude", transcript_path: path}})
    TranscriptIngest.poll()
    assert DynamicSupervisor.count_children(context.tail_supervisor).active == 0
    assert {:ok, binding} = Session.attach(%{harness: "claude"})
    assert {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: "one", transcript_path: nil})
    Phoenix.PubSub.broadcast(context.pubsub, "executor_hook", {:executor_hook, %{harness: "claude", transcript_path: nil}})
    TranscriptIngest.poll()
    assert DynamicSupervisor.count_children(context.tail_supervisor).active == 0
    assert :ok = flush(context.ref)
    assert rows(context.dir) == []
  end

  test "unreadable source recovers with a gap and never reads a replacement symlink", context do
    path = bind(context, "one", [assistant("first", "first")])
    start_ingest(context)
    TranscriptIngest.poll()
    saved = path <> ".saved"
    File.rename!(path, saved)
    target = transcript(context, "other", [assistant("secret", "secret")])
    File.ln_s!(target, path)
    TranscriptIngest.poll()
    File.rm!(path)
    File.rename!(saved, path)
    append(path, [assistant("second", "second")])
    TranscriptIngest.poll()
    assert :ok = flush(context.ref)
    assert Enum.map(rows(context.dir), & &1["body"]) == ["first", "", "second"]
    assert Enum.at(rows(context.dir), 1)["meta"]["reason"] == "source_unreadable"
  end

  test "idle polls checkpoint after two seconds and stale bindings cannot overwrite a new path", context do
    timer = start_supervised!({Agent, fn -> 0 end})
    context = Map.put(context, :clock, fn -> Agent.get(timer, & &1) end)
    path = bind(context, "one", [assistant("first", "first")])
    start_ingest(context)
    TranscriptIngest.poll()
    assert {:ok, first} = Session.current()
    append(path, [assistant("second", "second")])
    Agent.update(timer, fn _ -> 1000 end)
    TranscriptIngest.poll()
    assert {:ok, throttled} = Session.current()
    assert throttled.transcript_offset == first.transcript_offset
    Agent.update(timer, fn _ -> 2000 end)
    TranscriptIngest.poll()
    assert {:ok, checkpointed} = Session.current()
    assert checkpointed.transcript_offset == File.stat!(path).size
    next = Path.join(Path.dirname(path), "moved/one.jsonl")
    File.mkdir_p!(Path.dirname(next))
    File.write!(next, encode([assistant("new", "new")]))
    assert {:ok, rebound} = Session.bind_provider_session(first.binding_id, %{session_id: "one", transcript_path: next, pid: "123"})
    assert rebound.transcript_offset == 0
    assert {:error, :binding_changed} = Session.record_offset(checkpointed, 999)
    assert {:ok, current} = Session.current()
    assert current.transcript_offset == 0
  end

  test "failed journal fsync leaves the cursor resumable until a later successful flush", context do
    path = bind(context, "one", [assistant("first", "first")])
    TestSupport.actions(context.control, :append, List.duplicate({:error, :enospc}, 10))
    start_ingest(context)
    TranscriptIngest.poll()
    assert {:ok, binding} = Session.current()
    assert binding.transcript_offset == 0
    TestSupport.actions(context.control, :append, [])
    TranscriptIngest.poll()
    assert {:ok, recovered} = Session.current()
    assert recovered.transcript_offset == File.stat!(path).size
    assert :ok = flush(context.ref)
    assert Enum.count(rows(context.dir), &(&1["body"] == "first")) == 1
  end

  test "recording starts the capture manager after its session and dynamic supervisor" do
    specs = Aiur.Application.child_specs(interactive_cli?: false, headless?: true, dashboard?: false, recording?: true)

    modules =
      Enum.map(specs, fn
        module when is_atom(module) -> module
        {module, _} -> module
        %{id: id} -> id
      end)

    assert TranscriptIngest in modules
    assert Enum.find_index(modules, &(&1 == Session)) < Enum.find_index(modules, &(&1 == TranscriptIngest))
  end

  defp start_ingest(context),
    do:
      start_supervised!(
        {TranscriptIngest,
         home: context.home, pubsub: context.pubsub, supervisor: context.tail_supervisor, interval_ms: nil, clock: Map.get(context, :clock, fn -> System.monotonic_time(:millisecond) end)}
      )

  defp bind(context, id, records) do
    path = transcript(context, id, records)
    assert {:ok, binding} = Session.attach(%{harness: "claude"})
    assert {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: id, transcript_path: path, pid: "123"})
    path
  end

  defp transcript(context, id, records) do
    path = Path.join([context.home, ".claude/projects/project", id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(records))
    path
  end

  defp append(path, records), do: File.write!(path, encode(records), [:append])
  defp encode(records), do: Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n"))
  defp hash(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
  defp assistant(id, text), do: %{"type" => "assistant", "uuid" => id, "message" => %{"content" => [%{"type" => "text", "text" => text}]}}

  defp fixture do
    [
      %{
        "type" => "assistant",
        "uuid" => "a",
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "answer"},
            %{"type" => "thinking", "thinking" => "thought"},
            %{"type" => "tool_use", "id" => "call", "name" => "Bash", "input" => %{"command" => "pwd"}}
          ]
        }
      },
      %{"type" => "user", "uuid" => "u", "message" => %{"content" => "prompt"}},
      %{"type" => "user", "uuid" => "r", "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => "call", "content" => "/repo"}]}},
      %{"type" => "attachment", "uuid" => "rc", "attachment" => %{"type" => "queued_command", "commandMode" => "prompt", "prompt" => "phone"}}
    ]
  end
end
