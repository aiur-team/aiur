defmodule VoiceConverse.UsageTest do
  use ExUnit.Case, async: true

  alias VoiceConverse.Usage

  describe "new/1 and snapshot/1" do
    test "starts with known zero audio and unknown provider readings" do
      assert {:ok, usage} = Usage.new("voice-123")

      assert Usage.snapshot(usage) == %{
               session_id: "voice-123",
               input_tokens: nil,
               output_tokens: nil,
               total_tokens: nil,
               input_audio_seconds: 0.0,
               output_audio_seconds: 0.0,
               estimated_cost_usd: nil
             }
    end

    test "rejects an empty session identifier" do
      assert {:error, :invalid_session_id} = Usage.new("")
    end
  end

  describe "add_model_delta/2" do
    test "accumulates reported deltas and keeps unreported dimensions unknown" do
      {:ok, usage} = Usage.new("voice-123")

      assert {:ok, usage} =
               Usage.add_model_delta(usage, %{input_tokens: 10, total_tokens: 10, estimated_cost_usd: 0.01})

      assert {:ok, usage} =
               Usage.add_model_delta(usage, %{
                 input_tokens: 5,
                 output_tokens: 3,
                 total_tokens: 8,
                 estimated_cost_usd: 0.02
               })

      assert %{
               input_tokens: 15,
               output_tokens: 3,
               total_tokens: 18,
               estimated_cost_usd: cost
             } = Usage.snapshot(usage)

      assert_in_delta cost, 0.03, 1.0e-12
    end

    test "does not infer an input/output split from total tokens" do
      {:ok, usage} = Usage.new("voice-123")

      assert {:ok, usage} = Usage.add_model_delta(usage, %{total_tokens: 42})

      assert %{input_tokens: nil, output_tokens: nil, total_tokens: 42} = Usage.snapshot(usage)
    end

    test "distinguishes a reported zero from an unknown reading" do
      {:ok, usage} = Usage.new("voice-123")

      assert {:ok, usage} =
               Usage.add_model_delta(usage, %{
                 input_tokens: 0,
                 output_tokens: 0,
                 total_tokens: 0,
                 estimated_cost_usd: 0
               })

      assert %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               estimated_cost_usd: +0.0
             } = Usage.snapshot(usage)
    end

    test "rejects negative and non-numeric readings without changing the prior value" do
      {:ok, usage} = Usage.new("voice-123")
      {:ok, usage} = Usage.add_model_delta(usage, %{input_tokens: 4})

      assert {:error, :invalid_model_usage} = Usage.add_model_delta(usage, %{output_tokens: -1})
      assert {:error, :invalid_model_usage} = Usage.add_model_delta(usage, %{estimated_cost_usd: -0.01})
      assert {:error, :invalid_model_usage} = Usage.add_model_delta(usage, %{estimated_cost_usd: "free"})
      assert {:error, :invalid_model_usage} = Usage.add_model_delta(usage, %{tokens: %{total: 4}})
      assert %{input_tokens: 4, output_tokens: nil, estimated_cost_usd: nil} = Usage.snapshot(usage)
    end
  end

  describe "add_audio/4" do
    test "accumulates input and mixed-rate output PCM duration" do
      {:ok, usage} = Usage.new("voice-123")

      input = Base.encode64(:binary.copy(<<0>>, 32_000))
      output_16k = Base.encode64(:binary.copy(<<0>>, 16_000))
      output_24k = Base.encode64(:binary.copy(<<0>>, 24_000))
      output_44k = Base.encode64(:binary.copy(<<0>>, 44_100))

      assert {:ok, usage} = Usage.add_audio(usage, :input, :pcm_16000, input)
      assert {:ok, usage} = Usage.add_audio(usage, :output, :pcm_16000, output_16k)
      assert {:ok, usage} = Usage.add_audio(usage, :output, :pcm_24000, output_24k)
      assert {:ok, usage} = Usage.add_audio(usage, :output, :pcm_44100, output_44k)

      assert %{input_audio_seconds: 1.0, output_audio_seconds: 1.5} = Usage.snapshot(usage)
    end

    test "accepts an empty chunk as known zero duration" do
      {:ok, usage} = Usage.new("voice-123")

      assert {:ok, usage} = Usage.add_audio(usage, :input, :pcm_16000, "")
      assert %{input_audio_seconds: +0.0} = Usage.snapshot(usage)
    end

    test "rejects invalid PCM without changing the prior value" do
      {:ok, usage} = Usage.new("voice-123")
      valid = Base.encode64(:binary.copy(<<0>>, 32_000))

      assert {:ok, usage} = Usage.add_audio(usage, :input, :pcm_16000, valid)
      assert {:error, :invalid_audio} = Usage.add_audio(usage, :input, :pcm_16000, "not base64")
      assert {:error, :invalid_audio} = Usage.add_audio(usage, :input, :pcm_16000, Base.encode64(<<0>>))
      assert {:error, :invalid_audio} = Usage.add_audio(usage, :sideways, :pcm_16000, "")
      assert {:error, :invalid_audio} = Usage.add_audio(usage, :input, :pcm_8000, "")

      assert %{input_audio_seconds: 1.0, output_audio_seconds: +0.0} = Usage.snapshot(usage)
    end
  end
end
