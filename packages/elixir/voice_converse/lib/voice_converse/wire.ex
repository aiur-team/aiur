defmodule VoiceConverse.Wire do
  @moduledoc """
  Versioned JSON codec for the transport-neutral VoiceConverse protocol.

  Frames are JSON objects with a stable `v: 1` marker and a `type` discriminator.
  Unknown fields survive decoding so v1 clients remain compatible with additive fields.
  """

  @version 1
  @client_types ~w(start audio text confirm_draft discard_draft end)
  @server_types ~w(state transcript agent_text agent_audio interrupted draft delivery context_gap error ended)
  @types @client_types ++ @server_types
  @required %{
    "start" => ["target"],
    "audio" => ["data_b64"],
    "text" => ["text"],
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
      {:ok, Jason.encode!(frame)}
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
    if Enum.all?(@required[type], &Map.has_key?(frame, &1)), do: :ok, else: {:error, :invalid_frame}
  end

  defp validate(%{"v" => version}) when is_integer(version) and version != @version, do: {:error, :unsupported_version}
  defp validate(_), do: {:error, :invalid_frame}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
