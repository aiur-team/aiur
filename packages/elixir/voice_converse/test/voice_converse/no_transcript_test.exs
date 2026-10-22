defmodule VoiceConverse.NoTranscriptTest do
  # `transcript: :none` exists for audiences (e.g. minors) whose conversations must not be stored
  # at all. A leak here is a privacy breach, so every test checks the disk, not just return values.
  use ExUnit.Case, async: true

  alias VoiceConverse.{Config, TranscriptStore}
  alias VoiceConverse.Testing.{FakeBriefingSource, StaticCredentials}

  @id "vc_" <> String.duplicate("b", 22)
  @started %{target: "worker-1", role_id: "default", provider: "fake"}
  @ports [credentials: StaticCredentials, briefing_source: FakeBriefingSource]

  setup do
    dir = Path.join(System.tmp_dir!(), "voice_converse_no_transcript_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: dir}
  end

  defp run_session(config) do
    {:ok, store} = TranscriptStore.start(config, @id, @started, sync_fs: fn -> :ok end)
    :ok = TranscriptStore.append(store, %{type: "user_turn", turn_id: "t1", text: "my name is Sam"})
    :ok = TranscriptStore.append(store, %{type: "assistant_turn", turn_id: "t1", text: "hi Sam"})
    :ok = TranscriptStore.append(store, %{type: "session_ended", reason: "user"})
    :ok = TranscriptStore.close(store)
    store
  end

  test "a no-transcript config needs no transcript_root and reports its mode" do
    assert {:ok, %Config{transcript: :none, transcript_root: nil}} = Config.new([transcript: :none] ++ @ports)
  end

  test "the default mode still stores transcripts and still requires a root" do
    assert {:ok, %Config{transcript: :file}} = Config.new([transcript_root: "/tmp/vc"] ++ @ports)
    assert {:error, %{field: :transcript_root, reason: :missing}} = Config.new(@ports)
  end

  # Fail safe: a typo must not silently pick either mode.
  test "an unknown transcript mode is rejected at validation" do
    for mode <- [:off, "none", nil, false] do
      assert {:error, %{field: :transcript, reason: :invalid}} =
               Config.new([transcript: mode, transcript_root: "/tmp/vc"] ++ @ports)
    end
  end

  test "a no-transcript session writes nothing, even when a root is configured", %{root: root} do
    {:ok, config} = Config.new([transcript: :none, transcript_root: root] ++ @ports)

    store = run_session(config)

    assert TranscriptStore.mode(store) == :none
    assert File.ls!(root) == []
    assert {:error, :not_found} = TranscriptStore.read(root, @id)
  end

  test "a no-transcript session without a root creates no directory anywhere", %{root: root} do
    {:ok, config} = Config.new([transcript: :none] ++ @ports)
    cwd_before = File.ls!(File.cwd!())

    assert TranscriptStore.mode(run_session(config)) == :none
    assert File.ls!(File.cwd!()) == cwd_before
    assert File.ls!(root) == []
  end

  test "the default mode writes the session to its root", %{root: root} do
    {:ok, config} = Config.new([transcript_root: root] ++ @ports)

    store = run_session(config)

    assert TranscriptStore.mode(store) == :file
    assert File.ls!(root) == [@id <> ".ndjson"]

    assert {:ok, [%{"type" => "session_started"}, %{"text" => "my name is Sam"}, _, %{"type" => "session_ended"}], _} =
             TranscriptStore.read(root, @id)
  end
end
