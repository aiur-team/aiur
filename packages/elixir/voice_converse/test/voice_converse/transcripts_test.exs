defmodule VoiceConverse.TranscriptsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias VoiceConverse.{TestCleanup, TranscriptIndex, Transcripts, TranscriptStore}
  @id "vc_aaaaaaaaaaaaaaaaaaaaaa"
  @other "vc_bbbbbbbbbbbbbbbbbbbbbb"

  setup do
    root = Path.join(System.tmp_dir!(), "transcripts_cli_#{System.unique_integer([:positive])}")
    on_exit(fn -> TestCleanup.rm_rf!(root) end)
    %{root: root}
  end

  test "lists sessions for a target and round trips index JSON", %{root: root} do
    write(root, @id, %{"id" => "executor", "kind" => "executor", "title" => "Executor"}, [
      %{type: "draft", draft_id: "vd_1", status: "proposed", text: "hello"},
      %{type: "user_turn", text: "hello"}
    ])

    write(root, @other, "4140", [])
    assert {:ok, output} = Transcripts.run(root, ["--target", "executor"])
    assert output =~ @id
    refute output =~ @other
    assert output =~ "unknown  unknown  1  0/1/0/0"
    assert {:ok, all} = Transcripts.run(root, [])
    assert all =~ "unknown  unknown  0  0/0/0/0"
    assert {:ok, json} = Transcripts.run(root, ["--target", "executor", "--json"])
    assert {:ok, expected, nil} = TranscriptIndex.list(root, filter: %{target: "executor"})
    assert Jason.decode!(json) == Jason.decode!(Jason.encode!(expected))
    assert {:ok, limited} = Transcripts.run(root, ["--limit", "1", "--json"])
    assert length(Jason.decode!(limited)) == 1
  end

  test "shows transcript in order with context tools drafts and outcomes", %{root: root} do
    write(root, @id, %{"id" => "executor", "kind" => "executor", "title" => "Executor"}, [
      %{type: "context", source: "briefing", observed_at: "2026-10-24T10:00:00Z", text: "Context facts"},
      %{type: "user_turn", text: "hello"},
      %{type: "assistant_turn", text: "hi"},
      %{type: "tool_call", name: "get_status", params: %{ticket: "4140"}},
      %{type: "tool_result", name: "get_status", summary: "ready"},
      %{type: "draft", draft_id: "vd_1", status: "sent", text: "start"},
      %{type: "delivery", draft_id: "vd_1", status: "delivered", text: "accepted"},
      %{type: "session_ended", reason: "user_end", duration_s: 60}
    ])

    assert {:ok, output} = Transcripts.run(root, [@id])
    assert [_, context, user, assistant, call, result, draft, delivery, ended] = String.split(output, "\n")
    assert context == "[10:01:00] context(briefing, observed 60s before record): Context facts"
    assert user == "[10:01:00] you: hello"
    assert assistant == "[10:01:00] assistant: hi"
    assert call == ~s([10:01:00] tool get_status → {"ticket":"4140"})
    assert result == "[10:01:00] tool get_status → ready"
    assert draft == "[10:01:00] draft vd_1 sent: start"
    assert delivery == "[10:01:00] delivery vd_1 delivered: accepted"
    assert ended =~ "user_end"
    assert {:ok, listing} = Transcripts.run(root, [])
    assert listing =~ "60s  user_end  1  1/0/0/0"
    assert {:ok, records, _} = TranscriptStore.read(root, @id)
    assert {:ok, json} = Transcripts.run(root, [@id, "--json"])
    assert Jason.decode!(json) == records
  end

  test "full JSON is not truncated to the index API page size", %{root: root} do
    write(
      root,
      @id,
      %{"id" => "executor", "kind" => "executor", "title" => "Executor"},
      for(n <- 1..501, do: %{type: "user_turn", text: "turn #{n}"})
    )

    assert {:ok, json} = Transcripts.run(root, [@id, "--json"])
    assert length(Jason.decode!(json)) == 502
    assert List.last(Jason.decode!(json))["text"] == "turn 501"
  end

  test "empty missing and invalid requests have distinct outcomes", %{root: root} do
    assert {:ok, "No voice conversations recorded."} = Transcripts.run(root, [])
    assert {:ok, "[]"} = Transcripts.run(root, ["--json"])
    assert capture_io(:stderr, fn -> assert Transcripts.print(root, [@id]) == 1 end) == "No such conversation\n"

    for args <- [["../oops"], ["--limit", "0"], ["--target", "bad\""], [@id, "--limit", "1"], ["--unknown"]] do
      assert {:error, :invalid_arguments} = Transcripts.run(root, args)
    end
  end

  test "reports damaged records and unknown observation ages", %{root: root} do
    write(root, @id, %{"id" => "executor", "kind" => "executor", "title" => "Executor"}, [
      %{type: "context", source: "gaps", text: "unavailable"}
    ])

    File.write!(
      Path.join(root, @id <> ".ndjson"),
      "bad\n" <> Jason.encode!(%{type: "assistant_turn", text: "intact"}) <> "\n{",
      [:append]
    )

    assert {:ok, output} = Transcripts.run(root, [@id])
    assert output =~ "context(gaps, observed unknown): unavailable"
    assert output =~ "assistant: intact"
    assert output =~ "(skipped invalid records at lines 3)"
    assert String.ends_with?(output, "(last record incomplete)")
    assert {:ok, json} = Transcripts.run(root, [@id, "--json"])
    assert length(Jason.decode!(json)) == 3
  end

  test "standalone Mix task uses explicit root", %{root: root} do
    write(root, @id, %{"id" => "executor", "kind" => "executor", "title" => "Executor"}, [])
    output = capture_io(fn -> Mix.Tasks.VoiceConverse.Transcripts.run(["--root", root, "--json"]) end)
    assert [%{"conversation_id" => @id}] = Jason.decode!(output)
    assert_raise Mix.Error, "--root PATH is required", fn -> Mix.Tasks.VoiceConverse.Transcripts.run([]) end
  end

  defp write(root, id, target, records) do
    {:ok, store} = TranscriptStore.open(root, id, %{target: target, at: "2026-10-24T10:00:00Z"}, sync_fs: fn -> :ok end)
    for record <- records, do: :ok = TranscriptStore.append(store, Map.put(record, :at, "2026-10-24T10:01:00Z"))
    :ok = TranscriptStore.close(store)
  end
end
