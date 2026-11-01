defmodule VoiceConverse.Wire do
  @moduledoc """
  Versioned JSON codec for the transport-neutral VoiceConverse protocol.

  Frames are JSON objects with a stable `v: 1` marker and a `type` discriminator.
  Unknown fields survive decoding so v1 clients remain compatible with additive fields.
  """

  @version 1
  @client_types ~w(start audio text playback_state confirm_draft discard_draft end)
  @server_types ~w(state transcript agent_text agent_text_timing agent_audio interrupted draft delivery context_gap error ended)
  @types @client_types ++ @server_types
  @required %{
    "start" => ["target"],
    "audio" => ["data_b64"],
    "text" => ["text"],
    "playback_state" => ["state"],
    "agent_text_timing" => ["turn_id", "text", "audio_offset_ms", "estimated"],
    "confirm_draft" => ["draft_id"],
    "discard_draft" => ["draft_id"],
    "end" => [],
    "state" => ["state"],
    "transcript" => ["kind", "text"],
    "agent_text" => ["turn_id", "text", "final"],
    "agent_audio" => ["turn_id", "format", "data_b64"],
    "interrupted" => ["turn_id"],
    "draft" => ["draft_id", "kind", "target", "text", "status"],
    "delivery" => ["draft_id", "status"],
    "context_gap" => ["source", "message"],
    "error" => ["code", "message"],
    "ended" => ["reason"]
  }

  @type frame :: %{required(String.t()) => term()}

  @spec encode(frame() | map()) :: {:ok, binary()} | {:error, :invalid_frame | :unsupported_version}
  def encode(frame) when is_map(frame) do
    frame = stringify_keys(frame)

    with :ok <- validate(frame) do
      case Jason.encode(frame) do
        {:ok, json} -> {:ok, json}
        {:error, _reason} -> {:error, :invalid_frame}
      end
    end
  end

  def encode(_), do: {:error, :invalid_frame}

  @spec decode(binary()) :: {:ok, frame()} | {:error, :invalid_frame | :unsupported_version}
  def decode(json) when is_binary(json) do
    with {:ok, frame} when is_map(frame) <- Jason.decode(json),
         :ok <- validate(frame) do
      {:ok, frame}
    else
      {:error, :unsupported_version} -> {:error, :unsupported_version}
      {:error, _} -> {:error, :invalid_frame}
    end
  end

  def decode(_), do: {:error, :invalid_frame}

  defp validate(%{"v" => @version, "type" => type} = frame) when type in @types do
    if Enum.all?(@required[type], &Map.has_key?(frame, &1)) and valid_fields?(frame),
      do: :ok,
      else: {:error, :invalid_frame}
  end

  defp validate(%{"v" => version}) when is_integer(version) and version != @version, do: {:error, :unsupported_version}
  defp validate(_), do: {:error, :invalid_frame}

  defp valid_fields?(%{"type" => "playback_state"} = frame) do
    frame["state"] in ["playing", "stopped"] and
      (not Map.has_key?(frame, "turn_id") or is_binary(frame["turn_id"])) and
      (not Map.has_key?(frame, "played_until_ms") or
         (is_binary(frame["turn_id"]) and is_integer(frame["played_until_ms"]) and frame["played_until_ms"] >= 0))
  end

  defp valid_fields?(%{"type" => "agent_text_timing"} = frame) do
    is_binary(frame["turn_id"]) and is_binary(frame["text"]) and is_boolean(frame["estimated"]) and
      is_integer(frame["audio_offset_ms"]) and frame["audio_offset_ms"] >= 0 and valid_chars?(Map.get(frame, "chars"))
  end

  defp valid_fields?(_), do: true
  defp valid_chars?(nil), do: true

  defp valid_chars?(chars) when is_list(chars) do
    Enum.all?(chars, fn
      %{"offset_ms" => ms, "length" => length} -> is_integer(ms) and ms >= 0 and is_integer(length) and length > 0
      _ -> false
    end)
  end

  defp valid_chars?(_), do: false

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
