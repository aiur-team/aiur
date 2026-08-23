defmodule Aiur.Claude.DisplayTailerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Aiur.Claude.{DisplayTailer, HookEvents}
  alias Aiur.LiveConversation.Source

  # Build a claude on-disk transcript jsonl from raw record maps.
  defp write_jsonl(records) do
    path = Aiur.TestSupport.tmp_root!("display-tailer") <> ".jsonl"
    body = Enum.map_join(records, "", fn rec -> Jason.encode!(rec) <> "\n" end)
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp user_text(text), do: %{"type" => "user", "message" => %{"content" => text}, "timestamp" => "2026-06-13T12:00:00.000Z"}

  defp assistant_blocks(blocks),
    do: %{"type" => "assistant", "message" => %{"content" => blocks}, "timestamp" => "2026-06-13T12:00:00.000Z"}

  defp tool_result(output),
    do: %{
      "type" => "user",
      "message" => %{"content" => [%{"type" => "tool_result", "content" => output}]},
      "timestamp" => "2026-06-13T12:00:00.000Z"
    }

  defp start_tailer(identifier, opts \\ []) do
    tp = self()

    # start_supervised! ties the tailer's lifetime to the ExUnit supervisor, so
    # it survives the test body and is torn down cleanly (no link-death race
    # against on_exit, which a plain start_link + GenServer.stop hits).
    start_supervised!(
      {DisplayTailer,
       Keyword.merge(
         [
           identifier: identifier,
           on_message: fn msg -> send(tp, {:fwd, msg}) end,
           interval_ms: nil
         ],
         opts
       )}
    )
  end

  defp dispatch_path(identifier, path, session_id \\ nil) do
    event = %{"hook_event_name" => "PostToolUse", "transcript_path" => path}
    event = if is_binary(session_id), do: Map.put(event, "session_id", session_id), else: event
    HookEvents.dispatch(identifier, event)
  end

  # Collect the roles+bodies forwarded as transcript events.
  defp drain_forwarded do
    receive do
      {:fwd, %{event: :transcript, transcript_event: %{role: role, body: body}}} ->
        [{role, body} | drain_forwarded()]
    after
      100 -> []
    end
  end

  test "forwards the full conversation (user, thinking, assistant, tool i/o) in order", %{} do
    id = "MT-DT-FULL-#{System.unique_integer([:positive])}"

    path =
      write_jsonl([
        user_text("do the task"),
        assistant_blocks([
          %{"type" => "thinking", "thinking" => "I will check the dir"},
          %{"type" => "text", "text" => "Let me look"},
          %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "ls -la"}}
        ]),
        tool_result("total 8\nfile.ex"),
        assistant_blocks([%{"type" => "text", "text" => "All done"}])
      ])

    pid = start_tailer(id)
    dispatch_path(id, path)
    assert {:ok, n} = DisplayTailer.poll(pid)
    assert n >= 5

    forwarded = drain_forwarded()
    roles = Enum.map(forwarded, &elem(&1, 0))

    assert :user in roles
    assert :reasoning in roles
    assert :assistant in roles
    assert :command in roles
    # tool_result renders as a :tool event carrying the output
    assert :tool in roles

    assert {:user, "do the task"} in forwarded
    assert {:reasoning, "I will check the dir"} in forwarded
    assert {:assistant, "Let me look"} in forwarded
    assert {:assistant, "All done"} in forwarded
    assert {:command, "ls -la"} in forwarded
  end

  test "backfills history written before the first hook (from: :start)" do
    id = "MT-DT-BACKFILL-#{System.unique_integer([:positive])}"
    path = write_jsonl([user_text("earlier message"), assistant_blocks([%{"type" => "text", "text" => "earlier reply"}])])

    pid = start_tailer(id)
    dispatch_path(id, path)
    assert {:ok, n} = DisplayTailer.poll(pid)
    assert n >= 2

    forwarded = drain_forwarded()
    assert {:assistant, "earlier reply"} in forwarded
  end

  test "retargets to a new transcript on session rotation" do
    id = "MT-DT-ROTATE-#{System.unique_integer([:positive])}"
    path1 = write_jsonl([assistant_blocks([%{"type" => "text", "text" => "session one"}])])
    path2 = write_jsonl([assistant_blocks([%{"type" => "text", "text" => "session two"}])])
    test_pid = self()

    pid = start_tailer(id, on_source: fn event -> send(test_pid, {:source, event}) end)

    dispatch_path(id, path1, "session-one")
    assert_receive {:source, {:available, nil, "session-one", %{backfill?: true}}}
    assert {:ok, _} = DisplayTailer.poll(pid)

    assert_receive {:fwd,
                    %{
                      source_session_id: "session-one",
                      transcript_event: %{role: :assistant, body: "session one"}
                    }}

    assert DisplayTailer.current_session(pid) == "session-one"

    dispatch_path(id, path2, "session-two")
    assert_receive {:source, {:available, "session-one", "session-two", %{backfill?: true}}}
    assert {:ok, _} = DisplayTailer.poll(pid)

    assert_receive {:fwd,
                    %{
                      source_session_id: "session-two",
                      transcript_event: %{role: :assistant, body: "session two"}
                    }}

    assert DisplayTailer.current_session(pid) == "session-two"
  end

  test "a missing transcript path does not crash and recovers when a valid one arrives" do
    id = "MT-DT-MISSING-#{System.unique_integer([:positive])}"
    test_pid = self()
    pid = start_tailer(id, on_source: fn event -> send(test_pid, {:source, event}) end)

    dispatch_path(id, "/nonexistent/path/abc.jsonl", "missing-session")
    assert_receive {:source, {:unavailable, nil, "missing-session", :transcript_unavailable}}
    assert {:ok, 0} = DisplayTailer.poll(pid)
    assert Process.alive?(pid)
    assert drain_forwarded() == []

    path = write_jsonl([assistant_blocks([%{"type" => "text", "text" => "recovered"}])])
    dispatch_path(id, path, "missing-session")
    assert_receive {:source, {:available, "missing-session", "missing-session", %{backfill?: true}}}
    assert {:ok, _} = DisplayTailer.poll(pid)
    assert {:assistant, "recovered"} in drain_forwarded()
  end

  test "inner tailer loss reports authoritative health with correlated opaque logging" do
    id = "MT-DT-DOWN-#{System.unique_integer([:positive])}"
    raw_session = "provider-session-#{System.unique_integer([:positive])}"
    path = write_jsonl([assistant_blocks([%{"type" => "text", "text" => "before loss"}])])
    test_pid = self()

    pid =
      start_tailer(id,
        on_source: fn event -> send(test_pid, {:source, event}) end,
        log_context: "issue_id=gid-display issue_identifier=#{id} backend=claude-repl"
      )

    dispatch_path(id, path, raw_session)
    assert_receive {:source, {:available, nil, ^raw_session, %{backfill?: true}}}
    inner = :sys.get_state(pid).tailer

    log =
      capture_log(fn ->
        Process.exit(inner, :kill)

        assert_receive {:source, {:unavailable, ^raw_session, ^raw_session, :inner_tailer_down}},
                       2_000
      end)

    assert Process.alive?(pid)
    assert DisplayTailer.current_session(pid) == raw_session
    assert log =~ "issue_id=gid-display issue_identifier=#{id} backend=claude-repl"
    assert log =~ Source.opaque_session_id(raw_session)
    refute log =~ raw_session
  end

  test "a malformed jsonl line is skipped without crashing the tailer" do
    id = "MT-DT-GARBAGE-#{System.unique_integer([:positive])}"
    path = Aiur.TestSupport.tmp_root!("display-tailer-garbage") <> ".jsonl"

    File.write!(
      path,
      "{not valid json\n" <> Jason.encode!(assistant_blocks([%{"type" => "text", "text" => "after garbage"}])) <> "\n"
    )

    on_exit(fn -> File.rm(path) end)

    pid = start_tailer(id)
    dispatch_path(id, path)
    assert {:ok, _} = DisplayTailer.poll(pid)
    assert Process.alive?(pid)
    assert {:assistant, "after garbage"} in drain_forwarded()
  end

  test "tags attach-time history as display-only and later appends as live ingress" do
    id = "MT-DT-INGRESS-#{System.unique_integer([:positive])}"
    path = write_jsonl([assistant_blocks([%{"type" => "text", "text" => "old history"}])])
    pid = start_tailer(id)

    dispatch_path(id, path, "ingress-session")
    assert {:ok, 1} = DisplayTailer.poll(pid)

    assert_receive {:fwd,
                    %{
                      projection_ingress: :display_backfill,
                      transcript_event: %{body: "old history"}
                    }}

    File.write!(
      path,
      Jason.encode!(assistant_blocks([%{"type" => "text", "text" => "new live record"}])) <>
        "\n",
      [:append]
    )

    assert {:ok, 1} = DisplayTailer.poll(pid)

    assert_receive {:fwd,
                    %{
                      projection_ingress: :live,
                      transcript_event: %{body: "new live record"}
                    }}
  end

  test "buffers confirmed cold-start operator deliveries by request id and flushes once" do
    id = "MT-DT-BUFFER-#{System.unique_integer([:positive])}"
    path = write_jsonl([])
    test_pid = self()

    pid =
      start_tailer(id,
        on_operator_delivery: fn item, occurred_at, session_id ->
          send(test_pid, {:operator_delivery, item.id, occurred_at, session_id})
        end
      )

    item = %{id: 91, category: :operator_message, body: %{text: "accepted before hook"}}
    occurred_at = ~U[2026-07-17 12:00:00Z]

    assert :ok = DisplayTailer.buffer_operator_delivery(pid, item, occurred_at)
    assert :ok = DisplayTailer.buffer_operator_delivery(pid, item, occurred_at)
    refute_receive {:operator_delivery, _, _, _}, 100

    dispatch_path(id, path, "first-exact-session")

    assert_receive {:operator_delivery, 91, ^occurred_at, "first-exact-session"}
    refute_receive {:operator_delivery, 91, _, _}, 100

    raced_item = %{item | id: 92}
    assert :ok = DisplayTailer.buffer_operator_delivery(pid, raced_item, occurred_at)
    assert_receive {:operator_delivery, 92, ^occurred_at, "first-exact-session"}
  end

  test "bounds the unresolved operator delivery buffer to the newest 32 request ids" do
    id = "MT-DT-BUFFER-BOUND-#{System.unique_integer([:positive])}"
    pid = start_tailer(id)

    Enum.each(1..40, fn request_id ->
      item = %{id: request_id, category: :operator_message, body: %{text: "message #{request_id}"}}
      assert :ok = DisplayTailer.buffer_operator_delivery(pid, item, nil)
    end)

    assert Enum.map(:sys.get_state(pid).pending_operator_deliveries, & &1.request_id) ==
             Enum.to_list(9..40)
  end

  test "self-stops when its owning run process dies (no orphan)" do
    id = "MT-DT-OWNER-#{System.unique_integer([:positive])}"
    tp = self()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    {:ok, pid} =
      DisplayTailer.start(
        identifier: id,
        on_message: fn _ -> :ok end,
        interval_ms: nil,
        owner: owner
      )

    ref = Process.monitor(pid)
    assert Process.alive?(pid)

    send(owner, :stop)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    refute Process.alive?(pid)
    _ = tp
  end

  test "caps oversized bodies with an elision marker" do
    id = "MT-DT-CAP-#{System.unique_integer([:positive])}"
    big = String.duplicate("x", 50_000)
    path = write_jsonl([assistant_blocks([%{"type" => "text", "text" => big}])])

    pid = start_tailer(id, max_body: 1_000)
    dispatch_path(id, path)
    assert {:ok, _} = DisplayTailer.poll(pid)

    forwarded = drain_forwarded()
    assert [{:assistant, body}] = Enum.filter(forwarded, &match?({:assistant, _}, &1))
    assert byte_size(body) < 2_000
    assert body =~ "truncated"
  end
end
