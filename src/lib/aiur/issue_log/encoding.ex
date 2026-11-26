defmodule Aiur.IssueLog.Encoding do
  @moduledoc false

  @max_transcript_record_bytes 16_384
  @truncated_body_chars 1_000
  @truncated_diff_chars 2_000

  @spec max_record_bytes() :: pos_integer()
  def max_record_bytes, do: @max_transcript_record_bytes

  @doc "Bounded, JSON-safe, encoded transcript record (no trailing newline)."
  @spec encode(term()) :: String.t()
  def encode(event), do: event |> persisted_transcript() |> bounded_transcript() |> json_safe() |> encode_transcript()

  # A tail page has a fixed byte budget. This is a second, defensive cap after
  # `bounded_transcript/1`, which prevents unbounded provider payloads from
  # being encoded in the first place.
  defp encode_transcript(record) do
    encoded = Jason.encode!(record)

    if byte_size(encoded) <= @max_transcript_record_bytes do
      encoded
    else
      record
      |> Map.take(["role", "timestamp", "msg_id", "sequence", "turn_id"])
      |> Map.put("body", truncated_body(Map.get(record, "body", "")))
      |> Map.put("payload", %{"truncated" => true})
      |> Jason.encode!()
    end
  end

  defp truncated_body(body) when is_binary(body) do
    if String.length(body) > @truncated_body_chars,
      do: String.slice(body, 0, @truncated_body_chars) <> "…",
      else: body
  end

  defp truncated_body(body), do: inspect(body)

  defp persisted_transcript({:transcript_event, event}) when is_map(event), do: event

  defp persisted_transcript({:alert, event}) when is_map(event) do
    %{
      role: :alert,
      body: Map.get(event, :message, ""),
      timestamp: Map.get(event, :timestamp, DateTime.utc_now()),
      msg_id: nil,
      sequence: nil,
      turn_id: nil,
      payload: event
    }
  end

  defp persisted_transcript(event) when is_map(event), do: event

  # The feed needs a message body and, for edit tools, the provider's real
  # unified diff. Shell output and generic tool payloads can be arbitrarily
  # large, so drop them before JSON encoding rather than paying their memory
  # cost only to reject an oversized record afterward.
  defp bounded_transcript(%{role: :tool, payload: %{tool: "edit", output: output} = payload} = event) when is_binary(output) do
    %{event | body: truncated_body(event.body), payload: bounded_edit_payload(payload, output)}
  end

  defp bounded_transcript(%{body: body} = event) do
    %{event | body: truncated_body(body), payload: nil}
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  # `nil`, `true` and `false` are atoms in Elixir, so the generic atom clause
  # below used to persist them as the strings "nil"/"true"/"false". A stringified
  # `turn_id` is not merely ugly: `"nil"` is truthy, so every turn-less entry in
  # a transcript compared equal to every other one and the Stream Deck's
  # group-by-turn collapsed a whole page of activity into a single event key.
  # JSON has native literals for all three; use them.
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp bounded_edit_payload(payload, output) do
    %{tool: "edit", output: String.slice(output, 0, @truncated_diff_chars)}
    |> maybe_put_edit_changes(Map.get(payload, :input) || Map.get(payload, "input"))
  end

  defp maybe_put_edit_changes(payload, input) when is_map(input) do
    case Map.get(input, :changes) || Map.get(input, "changes") do
      changes when is_list(changes) ->
        diffs = Enum.flat_map(changes, &bounded_edit_change/1)
        if diffs == [], do: payload, else: Map.put(payload, :changes, diffs)

      _ ->
        payload
    end
  end

  defp maybe_put_edit_changes(payload, _input), do: payload

  defp bounded_edit_change(change) when is_map(change) do
    case Map.get(change, :diff) || Map.get(change, "diff") do
      diff when is_binary(diff) and diff != "" ->
        [%{diff: String.slice(diff, 0, @truncated_diff_chars)} |> maybe_put_path(Map.get(change, :path) || Map.get(change, "path"))]

      _ ->
        []
    end
  end

  defp bounded_edit_change(_change), do: []

  defp maybe_put_path(change, path) when is_binary(path) and path != "", do: Map.put(change, :path, path)
  defp maybe_put_path(change, _path), do: change
end
