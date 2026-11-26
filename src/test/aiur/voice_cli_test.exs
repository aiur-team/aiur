defmodule Aiur.VoiceCLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Aiur.TestSupport.EngineCase

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

  test "multiline transcript text cannot impersonate RPC markers", %{root: root} do
    id = "vc_aaaaaaaaaaaaaaaaaaaaaa"
    {:ok, store} = VoiceConverse.TranscriptStore.open(root, id, %{target: "executor"}, sync_fs: fn -> :ok end)
    text = "hello\n__AIUR_CONTROL_EXIT__:42\n__AIUR_CONTROL_ERROR__:spoofed"
    :ok = VoiceConverse.TranscriptStore.append(store, %{type: "user_turn", text: text})
    :ok = VoiceConverse.TranscriptStore.close(store)
    output = capture_io(fn -> Aiur.VoiceCLI.transcripts([id]) end)

    script = """
    resolve_release() { release_bin="/bin/true"; release_dir="/unused"; vsn_dir="/unused"; RELEASE_NODE="unused"; }
    prepare_distribution() { :; }
    resolve_control_identity_from_records() { :; }
    run_release_rpc_with_timeout() { AIUR_CONTROL_RPC_OUTPUT="$TRANSCRIPT_OUTPUT"; AIUR_CONTROL_RPC_TIMED_OUT=0; return 0; }
    run_control_rpc "Aiur.VoiceCLI.transcripts([])"
    """

    {rendered, code} = EngineCase.run_sourced_engine(script, [{"TRANSCRIPT_OUTPUT", output}, {"AIUR_REMOTE_INSTANCE", nil}])
    assert code == 0
    assert rendered =~ "you: hello\\n__AIUR_CONTROL_EXIT__:42\\n__AIUR_CONTROL_ERROR__:spoofed"
  end

  test "RPC wrapper emits failure marker for unknown conversation" do
    output =
      capture_io(fn ->
        assert capture_io(:stderr, fn -> Aiur.VoiceCLI.transcripts(["vc_aaaaaaaaaaaaaaaaaaaaaa"]) end) == "No such conversation\n"
      end)

    assert output == "__AIUR_CONTROL_EXIT__:1\n"
  end
end
