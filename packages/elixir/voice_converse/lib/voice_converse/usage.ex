defmodule VoiceConverse.Usage do
  @moduledoc """
  Host-neutral cumulative accounting for one voice session.

  Model readings are per-operation deltas. Missing readings stay unknown until a provider reports
  them; reported zeroes are preserved as measurements. Audio is raw 16-bit little-endian mono PCM,
  so its duration is derived from the decoded byte count and the chunk's declared sample rate.
  """

  @model_keys [:input_tokens, :output_tokens, :total_tokens, :estimated_cost_usd]
  @formats [:pcm_16000, :pcm_24000, :pcm_44100]

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            input_tokens: nil,
            output_tokens: nil,
            total_tokens: nil,
            input_audio_seconds: 0.0,
            output_audio_seconds: 0.0,
            estimated_cost_usd: nil

  @type t :: %__MODULE__{
          session_id: String.t(),
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          input_audio_seconds: float(),
          output_audio_seconds: float(),
          estimated_cost_usd: float() | nil
        }

  @type model_delta :: %{
          optional(:input_tokens) => non_neg_integer() | nil,
          optional(:output_tokens) => non_neg_integer() | nil,
          optional(:total_tokens) => non_neg_integer() | nil,
          optional(:estimated_cost_usd) => number() | nil
        }

  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_session_id}
  def new(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    {:ok, %__MODULE__{session_id: session_id}}
  end

  def new(_session_id), do: {:error, :invalid_session_id}

  @doc "Returns the cumulative, wire-neutral readings for the session."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = usage), do: Map.from_struct(usage)

  @doc "Adds one normalized model-usage delta to the cumulative readings."
  @spec add_model_delta(t(), model_delta()) :: {:ok, t()} | {:error, :invalid_model_usage}
  def add_model_delta(%__MODULE__{} = usage, delta) when is_map(delta) do
    with :ok <- validate_model_delta(delta) do
      updated =
        Enum.reduce(@model_keys, usage, fn key, acc ->
          case Map.fetch(delta, key) do
            {:ok, value} when not is_nil(value) -> Map.update!(acc, key, &add_reading(&1, value, key))
            _absent_or_unknown -> acc
          end
        end)

      {:ok, updated}
    end
  end

  def add_model_delta(_usage, _delta), do: {:error, :invalid_model_usage}

  @doc "Adds one base64-encoded PCM chunk to the selected audio direction."
  @spec add_audio(t(), :input | :output, VoiceConverse.Events.AgentAudio.format(), String.t()) ::
          {:ok, t()} | {:error, :invalid_audio}
  def add_audio(%__MODULE__{} = usage, direction, format, data_b64)
      when direction in [:input, :output] and format in @formats and is_binary(data_b64) do
    with {:ok, pcm} <- Base.decode64(data_b64),
         true <- rem(byte_size(pcm), 2) == 0 do
      field = if(direction == :input, do: :input_audio_seconds, else: :output_audio_seconds)
      sample_rate = VoiceConverse.Narration.sample_rate(format)
      seconds = byte_size(pcm) / (sample_rate * 2)
      {:ok, Map.update!(usage, field, &(&1 + seconds))}
    else
      _invalid -> {:error, :invalid_audio}
    end
  end

  def add_audio(_usage, _direction, _format, _data_b64), do: {:error, :invalid_audio}

  defp validate_model_delta(delta) do
    valid? =
      Enum.all?(delta, fn
        {key, value} when key in [:input_tokens, :output_tokens, :total_tokens] ->
          is_nil(value) or (is_integer(value) and value >= 0)

        {:estimated_cost_usd, value} ->
          is_nil(value) or (is_number(value) and value >= 0)

        _unknown ->
          false
      end)

    if valid?, do: :ok, else: {:error, :invalid_model_usage}
  end

  defp add_reading(nil, value, :estimated_cost_usd), do: value * 1.0
  defp add_reading(nil, value, _key), do: value
  defp add_reading(current, value, _key), do: current + value
end
