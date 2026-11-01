Code.require_file("../conversation/journal_support.exs", __DIR__)

defmodule Aiur.Executor.TranscriptDriftTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{Session, SessionCLI, TranscriptIngest}

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

    start_supervised!({Session, instance_key: "drift-test"})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    owner = self()

    opts = [
      home: context.root,
      pubsub: context.pubsub,
      supervisor: supervisor,
      interval_ms: nil,
      emit_alert: fn name, opts ->
        send(owner, {:drift, name, opts})
        :ok
      end
    ]

    Map.merge(context, %{opts: opts})
  end

  test "unknown rate alerts once per generation, survives restart, and never includes content", context do
    path = bind(context, "one")
    append(path, List.duplicate(%{"type" => "system"}, 195) ++ List.duplicate(%{"type" => "new", "text" => "PRIVATE"}, 4))
    start_supervised!({TranscriptIngest, context.opts})
    TranscriptIngest.poll()
    assert format()["total"] == 199
    refute_received {:drift, _, _}
    append(path, [%{"type" => "new", "body" => "PRIVATE"}])
    TranscriptIngest.poll()
    assert_received {:drift, "system.executor.transcript.drift", opts}
    assert opts[:needs_attention]
    assert opts[:exchange_payload].counts["types"] == %{"mapped" => 0, "ignored_known" => 195, "unknown" => 5}
    refute inspect(opts) =~ "PRIVATE"
    assert Enum.sort(Map.keys(opts[:exchange_payload])) == [:binding_id, :counts, :generation]
    append(path, [%{"type" => "new"}])
    TranscriptIngest.poll()
    refute_received {:drift, _, _}
    stop_supervised!(TranscriptIngest)
    stop_supervised!(Session)
    start_supervised!({Session, instance_key: "drift-test"})
    assert format()["alerted"]
    assert format()["total"] == 201
    start_supervised!({TranscriptIngest, context.opts})
    append(path, [%{"type" => "new"}])
    TranscriptIngest.poll()
    stop_supervised!(TranscriptIngest)
    assert format()["total"] == 202
    refute_received {:drift, _, _}
    bind(context, "two") |> append(List.duplicate(%{"type" => "new"}, 200))
    start_supervised!({TranscriptIngest, context.opts})
    TranscriptIngest.poll()
    assert_received {:drift, _, next}
    assert next[:exchange_payload].generation > opts[:exchange_payload].generation
    assert next[:exchange_payload].counts["total"] == 200
  end

  test "clear carries uncheckpointed counters and latch across files in the same generation", context do
    timer = start_supervised!({Agent, fn -> 0 end})
    opts = Keyword.put(context.opts, :clock, fn -> Agent.get(timer, & &1) end)
    path = bind(context, "old")
    append(path, List.duplicate(%{"type" => "system"}, 199))
    start_supervised!({TranscriptIngest, opts})
    TranscriptIngest.poll()
    append(path, List.duplicate(%{"type" => "new"}, 5))
    TranscriptIngest.poll()
    assert_received {:drift, _, _}
    {:ok, binding} = Session.current()
    assert binding.transcript_format["total"] == 199
    {:ok, _} = Session.prepare_clear_rebind(binding.binding_id, %{event: "SessionEnd", reason: "clear", harness: "claude", session_id: "old", pid: "123"})
    next_path = Path.join(Path.dirname(path), "new.jsonl")
    File.write!(next_path, "")
    {:ok, _} = Session.rebind_on_session_start(binding.binding_id, %{session_id: "new", harness: "claude", transcript_path: next_path, pid: "123", source: "clear"})
    TranscriptIngest.poll()
    TranscriptIngest.poll()
    append(next_path, List.duplicate(%{"type" => "new"}, 200))
    TranscriptIngest.poll()
    stop_supervised!(TranscriptIngest)
    assert format()["total"] == 404
    assert format()["alerted"]
    refute_received {:drift, _, _}
  end

  test "exactly two percent and absent versions do not alert; an untested version does", context do
    path = bind(context, "version")
    append(path, List.duplicate(%{"type" => "system", "version" => "2.1.291"}, 196) ++ List.duplicate(%{"type" => "new"}, 4))
    start_supervised!({TranscriptIngest, context.opts})
    TranscriptIngest.poll()
    refute_received {:drift, _, _}
    append(path, [%{"type" => "system", "version" => "2.1.300"}])
    TranscriptIngest.poll()
    assert_received {:drift, _, opts}
    assert opts[:exchange_payload].counts["untested_version"] == "2.1.300"
    assert opts[:exchange_payload].counts["versions"] == %{"tested" => 196, "absent" => 4, "untested" => 1}
    stop_supervised!(TranscriptIngest)
    json = capture_io(fn -> SessionCLI.run(json: true) end) |> Jason.decode!()
    assert json["transcript_format"]["total"] == 201
  end

  defp format do
    {:ok, binding} = Session.current()
    binding.transcript_format
  end

  defp bind(context, id) do
    path = Path.join([context.root, ".claude/projects/project", id <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    {:ok, binding} = Session.attach(%{harness: "claude", takeover?: true})
    {:ok, _} = Session.bind_provider_session(binding.binding_id, %{session_id: id, transcript_path: path, pid: "123"})
    path
  end

  defp append(path, records), do: File.write!(path, Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n")), [:append])
end
