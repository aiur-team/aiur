defmodule Aiur.VoiceCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    original = Application.fetch_env(:aiur, :conversation_state_dir)
    root = Path.join(System.tmp_dir!(), "voice-cli-#{System.unique_integer([:positive])}")
    Application.put_env(:aiur, :conversation_state_dir, root)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:aiur, :conversation_state_dir, value)
        :error -> Application.delete_env(:aiur, :conversation_state_dir)
      end

      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{root: Path.join(root, "voice")}
  end

  test "RPC wrapper uses host transcript root and emits success marker", %{root: root} do
    id = "vc_aaaaaaaaaaaaaaaaaaaaaa"
    {:ok, store} = VoiceConverse.TranscriptStore.open(root, id, %{target: "executor"}, sync_fs: fn -> :ok end)
    :ok = VoiceConverse.TranscriptStore.close(store)
    output = capture_io(fn -> assert :ok = Aiur.VoiceCLI.transcripts(["--json"]) end)
    [json, "__AIUR_CONTROL_EXIT__:0", ""] = String.split(output, "\n")
    assert [%{"conversation_id" => ^id, "target" => "executor"}] = Jason.decode!(json)
  end

  test "RPC wrapper emits failure marker for unknown conversation" do
    output =
      capture_io(fn ->
        assert capture_io(:stderr, fn -> Aiur.VoiceCLI.transcripts(["vc_aaaaaaaaaaaaaaaaaaaaaa"]) end) == "No such conversation\n"
      end)

    assert output == "__AIUR_CONTROL_EXIT__:1\n"
  end
end
