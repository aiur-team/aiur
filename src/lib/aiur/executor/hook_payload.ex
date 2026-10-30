defmodule Aiur.Executor.HookPayload do
  @moduledoc """
  Shared Claude/Codex hook normalizer for ingestion and future delivery.

  `normalize/2` takes a raw string-keyed payload and an explicit harness; returns
  `{:ok, event}` or `{:error, :invalid_payload}`. Unknown fields are discarded.
  Strings are capped at 4 KiB (identity fields at 256 bytes); identity overflow
  is rejected rather than truncated. Both transcript locators are validated.
  Rejections emit `[:aiur, :executor, :hook]` telemetry with count 1 and reason.
  """
  alias Aiur.Executor.TranscriptPath
  @fields ~w(cwd source turn_id agent_id agent_type last_assistant_message notification_type tool_name pid model permission_mode)a

  @spec normalize(term(), term(), keyword()) :: {:ok, map()} | {:error, :invalid_payload}
  def normalize(raw, harness, opts \\ [])

  def normalize(%{"session_id" => id, "hook_event_name" => event} = raw, harness, opts)
      when harness in ["claude", "codex"] and is_binary(id) and byte_size(id) in 1..256 and is_binary(event) and byte_size(event) in 1..256 do
    fields = Map.new(@fields, &{&1, bounded(raw[Atom.to_string(&1)])})
    normalized = Map.merge(fields, %{harness: harness, session_id: id, event: event, observed_at: DateTime.utc_now(), stop_hook_active: boolean(raw["stop_hook_active"])})
    normalized = Map.put(normalized, :transcript_path, path(raw["transcript_path"], harness, id, opts))
    {:ok, Map.put(normalized, :agent_transcript_path, path(raw["agent_transcript_path"], harness, id, Keyword.put(opts, :agent_id, fields.agent_id)))}
  end

  def normalize(_raw, _harness, _opts), do: {:error, :invalid_payload}

  @doc false
  @spec count(atom(), map()) :: :ok
  def count(reason, metadata \\ %{}), do: :telemetry.execute([:aiur, :executor, :hook], %{count: 1}, Map.put(metadata, :reason, reason))

  defp path(value, harness, id, opts) do
    case TranscriptPath.validate(value, harness, id, opts) do
      {:ok, path} ->
        path

      {:error, reason} ->
        count(:transcript_path_rejected, %{rejection: reason})
        nil
    end
  end

  defp bounded(value) when is_binary(value) and byte_size(value) <= 4096, do: value
  defp bounded(value) when is_binary(value), do: value |> binary_part(0, 4096) |> valid_prefix()
  defp bounded(_value), do: nil

  defp valid_prefix(value) do
    if String.valid?(value), do: value, else: value |> binary_part(0, byte_size(value) - 1) |> valid_prefix()
  end

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: nil
end
