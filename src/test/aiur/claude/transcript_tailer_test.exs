defmodule Aiur.Claude.TranscriptTailerTest do
  use ExUnit.Case, async: true

  alias Aiur.Claude.TranscriptTailer

  setup do
    path = Path.join(System.tmp_dir!(), "tailer-#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)
    %{path: path, test_pid: self()}
  end

  defp start_tailer(path, test_pid, opts \\ []) do
    on_message = fn event -> send(test_pid, {:event, event}) end

    {:ok, pid} =
      start_supervised(
        {TranscriptTailer,
         Keyword.merge(
           [path: path, on_message: on_message, turn_id: "turn-1", interval_ms: nil, from: :start],
           opts
         )},
        id: {:tailer, System.unique_integer([:positive])}
      )

    pid
  end

  defp assistant_line(text) do
    Jason.encode!(%{
      "type" => "assistant",
      "timestamp" => "2026-06-08T12:00:00.000Z",
      "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
    }) <> "\n"
  end

  test "emits one event for an appended assistant text record", %{path: path, test_pid: tp} do
    File.write!(path, assistant_line("Hello"))
    tailer = start_tailer(path, tp)

    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, event}
    assert event.role == :assistant
    assert event.body == "Hello"
    assert event.turn_id == "turn-1"
  end

  test "does not emit a partial trailing line until it is completed", %{path: path, test_pid: tp} do
    full = assistant_line("Complete")
    {head, tail} = String.split_at(full, byte_size(full) - 5)

    File.write!(path, head)
    tailer = start_tailer(path, tp)

    assert {:ok, 0} = TranscriptTailer.poll(tailer)
    refute_receive {:event, _}, 100

    File.write!(path, head <> tail)
    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, event}
    assert event.body == "Complete"
  end

  test "skips bridge-session / system / file-history-snapshot records", %{path: path, test_pid: tp} do
    lines =
      Enum.map_join(
        ["bridge-session", "system", "file-history-snapshot"],
        "",
        &(Jason.encode!(%{"type" => &1, "message" => %{}}) <> "\n")
      )

    File.write!(path, lines <> assistant_line("only this"))
    tailer = start_tailer(path, tp)

    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, event}
    assert event.body == "only this"
  end

  test "advances across multiple polls without re-emitting", %{path: path, test_pid: tp} do
    File.write!(path, assistant_line("first"))
    tailer = start_tailer(path, tp)

    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, %{body: "first"}}

    File.write!(path, assistant_line("first") <> assistant_line("second"))
    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, %{body: "second"}}
    refute_receive {:event, %{body: "first"}}, 100
  end

  test "detects truncation/replacement and reads the new file from the start", %{path: path, test_pid: tp} do
    File.write!(path, assistant_line("old long content that makes the file big"))
    tailer = start_tailer(path, tp)
    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, _}

    # Replace with a shorter file (simulates a new UUID transcript / rotation).
    File.write!(path, assistant_line("new"))
    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, %{body: "new"}}
  end

  test "a cloud-authored record is emitted identically to a local one", %{path: path, test_pid: tp} do
    # The Claude app (Remote Control) appends the same on-disk shape; the
    # tailer cannot and need not tell the surfaces apart.
    File.write!(path, assistant_line("from the phone"))
    tailer = start_tailer(path, tp)

    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, event}
    assert event.role == :assistant
    assert event.body == "from the phone"
  end

  test "fires on_turn_end with the terminal stop_reason of an assistant record", %{path: path, test_pid: tp} do
    on_message = fn event -> send(tp, {:event, event}) end
    on_turn_end = fn reason -> send(tp, {:turn_end, reason}) end

    record =
      Jason.encode!(%{
        "type" => "assistant",
        "timestamp" => "2026-06-08T12:00:00.000Z",
        "message" => %{
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "Done."}]
        }
      }) <> "\n"

    File.write!(path, record)

    tailer_opts = [
      path: path,
      on_message: on_message,
      on_turn_end: on_turn_end,
      turn_id: "turn-1",
      interval_ms: nil,
      from: :start
    ]

    {:ok, tailer} =
      start_supervised(
        {TranscriptTailer, tailer_opts},
        id: {:tailer, System.unique_integer([:positive])}
      )

    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, %{body: "Done."}}
    assert_receive {:turn_end, "end_turn"}
  end

  test "fires on_turn_end for structured API-error records", %{path: path, test_pid: tp} do
    on_turn_end = fn signal -> send(tp, {:turn_end, signal}) end

    record =
      Jason.encode!(%{
        "type" => "system",
        "subtype" => "api_error",
        "error" => %{"status" => 429, "type" => "rate_limit_error"}
      }) <> "\n"

    File.write!(path, record)

    tailer_opts = [
      path: path,
      on_message: fn _ -> :ok end,
      on_turn_end: on_turn_end,
      turn_id: "turn-1",
      interval_ms: nil,
      from: :start
    ]

    {:ok, tailer} =
      start_supervised(
        {TranscriptTailer, tailer_opts},
        id: {:tailer, System.unique_integer([:positive])}
      )

    assert {:ok, 0} = TranscriptTailer.poll(tailer)
    assert_receive {:turn_end, {:error, %{"error" => %{"status" => 429}}}}
  end

  test "fires on_turn_end for failing API result records", %{path: path, test_pid: tp} do
    on_turn_end = fn signal -> send(tp, {:turn_end, signal}) end

    File.write!(
      path,
      Jason.encode!(%{"type" => "result", "is_error" => true, "api_error_status" => 429}) <> "\n"
    )

    tailer_opts = [
      path: path,
      on_message: fn _ -> :ok end,
      on_turn_end: on_turn_end,
      turn_id: "turn-1",
      interval_ms: nil,
      from: :start
    ]

    {:ok, tailer} =
      start_supervised(
        {TranscriptTailer, tailer_opts},
        id: {:tailer, System.unique_integer([:positive])}
      )

    assert {:ok, 0} = TranscriptTailer.poll(tailer)
    assert_receive {:turn_end, {:error, %{"api_error_status" => 429}}}
  end

  test "does not fire on_turn_end for an intra-turn (tool_use) assistant record", %{path: path, test_pid: tp} do
    on_turn_end = fn reason -> send(tp, {:turn_end, reason}) end

    record =
      Jason.encode!(%{
        "type" => "assistant",
        "timestamp" => "2026-06-08T12:00:00.000Z",
        "message" => %{
          "role" => "assistant",
          "stop_reason" => "tool_use",
          "content" => [%{"type" => "text", "text" => "Working."}]
        }
      }) <> "\n"

    File.write!(path, record)

    tailer_opts = [
      path: path,
      on_message: fn _ -> :ok end,
      on_turn_end: on_turn_end,
      turn_id: "turn-1",
      interval_ms: nil,
      from: :start
    ]

    {:ok, tailer} =
      start_supervised(
        {TranscriptTailer, tailer_opts},
        id: {:tailer, System.unique_integer([:positive])}
      )

    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    refute_receive {:turn_end, _}, 100
  end

  test "from: :end ignores pre-existing history", %{path: path, test_pid: tp} do
    File.write!(path, assistant_line("history one") <> assistant_line("history two"))
    tailer = start_tailer(path, tp, from: :end)

    assert {:ok, 0} = TranscriptTailer.poll(tailer)
    refute_receive {:event, _}, 100

    File.write!(path, File.read!(path) <> assistant_line("brand new"))
    assert {:ok, 1} = TranscriptTailer.poll(tailer)
    assert_receive {:event, %{body: "brand new"}}
  end
end
