defmodule Aiur.Claude.DisplayTailerTest do
  use ExUnit.Case, async: false

  alias Aiur.Claude.{DisplayTailer, HookEvents}

  # Build a claude on-disk transcript jsonl from raw record maps.
  defp write_jsonl(records) do
    path = Path.join(System.tmp_dir!(), "display-tailer-#{System.unique_integer([:positive])}.jsonl")
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

    {:ok, pid} =
      DisplayTailer.start_link(
        Keyword.merge(
          [
            identifier: identifier,
            on_message: fn msg -> send(tp, {:fwd, msg}) end,
            interval_ms: nil
          ],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp dispatch_path(identifier, path) do
    HookEvents.dispatch(identifier, %{"hook_event_name" => "PostToolUse", "transcript_path" => path})
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

    pid = start_tailer(id)

    dispatch_path(id, path1)
    assert {:ok, _} = DisplayTailer.poll(pid)
    assert {:assistant, "session one"} in drain_forwarded()

    dispatch_path(id, path2)
    assert {:ok, _} = DisplayTailer.poll(pid)
    forwarded = drain_forwarded()
    assert {:assistant, "session two"} in forwarded
  end

  test "a missing transcript path does not crash and recovers when a valid one arrives" do
    id = "MT-DT-MISSING-#{System.unique_integer([:positive])}"
    pid = start_tailer(id)

    dispatch_path(id, "/nonexistent/path/abc.jsonl")
    assert {:ok, 0} = DisplayTailer.poll(pid)
    assert Process.alive?(pid)
    assert drain_forwarded() == []

    path = write_jsonl([assistant_blocks([%{"type" => "text", "text" => "recovered"}])])
    dispatch_path(id, path)
    assert {:ok, _} = DisplayTailer.poll(pid)
    assert {:assistant, "recovered"} in drain_forwarded()
  end

  test "a malformed jsonl line is skipped without crashing the tailer" do
    id = "MT-DT-GARBAGE-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "display-tailer-garbage-#{System.unique_integer([:positive])}.jsonl")

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
