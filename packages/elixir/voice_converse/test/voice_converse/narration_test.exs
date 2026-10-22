defmodule VoiceConverse.NarrationTest do
  use ExUnit.Case, async: false

  alias VoiceConverse.{Events, Narration}
  alias VoiceConverse.Testing.{FakeProvider, StaticCredentials}

  @secret "xi-test-secret-123"

  # A session-only provider: no render_speech/1.
  defmodule SessionOnlyProvider do
    def open(_spec), do: raise("a batch render must never open a session")
  end

  # Returns a raw provider term instead of an Events.Error.
  defmodule RawErrorProvider do
    def render_speech(_spec), do: {:error, "raw provider frame"}
  end

  setup do
    StaticCredentials.put(%{fake: @secret})
    on_exit(fn -> StaticCredentials.put(%{}) end)
    :ok
  end

  defp opts(extra \\ []), do: Keyword.merge([provider: FakeProvider, credentials: {StaticCredentials, :fake}], extra)

  @scripted %{
    audio: <<1, 0, 2, 0, 3, 0, 4, 0>>,
    format: :pcm_16000,
    alignment: [%{text: "Build", start_ms: 0, end_ms: 120}, %{text: "green", start_ms: 120, end_ms: 300}]
  }

  describe "render/2" do
    test "returns the provider's audio bytes and alignment unchanged" do
      assert {:ok, @scripted} == Narration.render("Build green", opts(fake: [render: @scripted]))
    end

    test "the default fake aligns one segment per word over audio of matching length" do
      assert {:ok, %{audio: audio, format: :pcm_16000, alignment: alignment}} =
               Narration.render("ci is green", opts(format: :pcm_16000))

      assert Enum.map(alignment, & &1.text) == ["ci", "is", "green"]
      assert List.last(alignment).end_ms == 750
      # 750 ms of 16-bit mono at 16 kHz: the alignment spans exactly the audio.
      assert byte_size(audio) == 16_000 * 2 * 750 / 1000
    end

    test "a provider without batch support is a clear :unsupported error" do
      assert {:error, :unsupported} = Narration.render("hello", opts(provider: SessionOnlyProvider))
    end

    test "a missing credential stops the render with a provider_auth error" do
      StaticCredentials.put(%{})

      assert {:error, %Events.Error{code: :provider_auth, message: "no credential for fake"}} =
               Narration.render("hello", opts(fake: [render: @scripted]))
    end

    test "the secret never appears in the result" do
      {:ok, result} = Narration.render("hello there", opts())
      refute inspect(result) =~ @secret
    end

    test "bad options name the field" do
      assert {:error, %{field: :text, reason: :empty}} = Narration.render("  ", opts())

      assert {:error, %{field: :provider, reason: :missing}} =
               Narration.render("hi", credentials: {StaticCredentials, :fake})

      assert {:error, %{field: :credentials, reason: :missing}} = Narration.render("hi", provider: FakeProvider)

      assert {:error, %{field: :credentials, reason: :invalid}} =
               Narration.render("hi", provider: FakeProvider, credentials: @secret)

      assert {:error, %{field: :format, reason: :unsupported}} = Narration.render("hi", opts(format: :mp3))
    end

    test "a provider failure passes through as an Error struct" do
      error = Events.Error.new(:provider_quota, "out of characters")
      assert {:error, ^error} = Narration.render("hi", opts(fake: [render_error: error]))
    end

    test "a malformed provider result becomes a provider_error, not raw provider data" do
      for bad <- [
            %{@scripted | audio: <<1, 2, 3>>},
            %{@scripted | format: :opus},
            %{@scripted | alignment: [%{text: "x", start_ms: 50, end_ms: 10}]},
            %{
              @scripted
              | alignment: [%{text: "b", start_ms: 200, end_ms: 300}, %{text: "a", start_ms: 0, end_ms: 100}]
            },
            %{"audio" => "raw provider frame"}
          ] do
        assert {:error, %Events.Error{code: :provider_error}} = Narration.render("hi", opts(fake: [render: bad]))
      end

      assert {:error, %Events.Error{code: :provider_error}} = Narration.render("hi", opts(provider: RawErrorProvider))
    end

    test "text over the character bound is refused before the provider is called" do
      long = String.duplicate("a", 5_001)
      assert {:error, %{field: :text, reason: :too_long}} = Narration.render(long, opts(provider: SessionOnlyProvider))
      assert {:error, %{field: :text, reason: :too_long}} = Narration.render("hello there", opts(max_chars: 5))
      assert {:ok, _} = Narration.render(String.duplicate("a", 5_000), opts())
    end

    test "a provider that does not answer by the deadline is killed and reported unavailable" do
      assert {:error, %Events.Error{code: :provider_unavailable, message: "render timed out"}} =
               Narration.render("hi", opts(timeout_ms: 20, fake: [render_delay: 5_000]))

      # The killed render leaves nothing behind for the caller.
      refute_received _
    end

    test "a non-Error render_error in the fake is a test bug, raised clearly" do
      assert_raise ArgumentError, ~r/render_error must be an Events.Error/, fn ->
        FakeProvider.render_speech(%{
          text: "hi",
          format: :pcm_16000,
          credentials: {StaticCredentials, :fake},
          fake: [render_error: "boom"]
        })
      end
    end
  end

  describe "render_to_file/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "voice_converse_narration_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{tmp_dir: dir}
    end

    test "writes a playable WAV of the rendered audio and returns the alignment", %{tmp_dir: dir} do
      path = Path.join(dir, "narration.wav")

      assert {:ok, %{path: ^path, format: :pcm_16000, alignment: alignment}} =
               Narration.render_to_file("Build green", path, opts(fake: [render: @scripted]))

      assert alignment == @scripted.alignment

      assert <<"RIFF", 44::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16, 16_000::little-32,
               32_000::little-32, 2::little-16, 16::little-16, "data", 8::little-32, audio::binary>> = File.read!(path)

      assert audio == @scripted.audio
      assert File.ls!(dir) == ["narration.wav"]
    end

    test "a failed render leaves the previous file untouched and no temp file", %{tmp_dir: dir} do
      path = Path.join(dir, "narration.wav")
      File.write!(path, "previous narration")
      StaticCredentials.put(%{})

      assert {:error, %Events.Error{code: :provider_auth}} = Narration.render_to_file("hi", path, opts())
      assert File.read!(path) == "previous narration"
      assert File.ls!(dir) == ["narration.wav"]
    end

    test "a successful render replaces the previous file whole", %{tmp_dir: dir} do
      path = Path.join(dir, "narration.wav")
      File.write!(path, "previous narration")

      assert {:ok, _} = Narration.render_to_file("Build green", path, opts(fake: [render: @scripted]))
      assert <<"RIFF", _::binary>> = File.read!(path)
      assert File.ls!(dir) == ["narration.wav"]
    end

    test "a destination that is a directory is a write error and leaves no temp file", %{tmp_dir: dir} do
      path = Path.join(dir, "narration.wav")
      File.mkdir_p!(path)

      assert {:error, {:write_failed, _}} = Narration.render_to_file("hi", path, opts())
      assert File.ls!(dir) == ["narration.wav"]
      assert File.ls!(path) == []
    end

    test "an unwritable destination is a write error and leaves nothing behind", %{tmp_dir: dir} do
      path = Path.join([dir, "missing", "narration.wav"])

      assert {:error, {:write_failed, :enoent}} = Narration.render_to_file("hi", path, opts())
      assert File.ls!(dir) == []
    end
  end
end
