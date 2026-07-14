defmodule Aiur.AgentEventLog do
  @moduledoc """
  Writes every agent event to the per-workspace structured event stream and
  materializes the compatibility markdown projection from the same record.

  - `agent.ndjson` — the structured, one-event-per-line JSON stream.
    `Aiur.AlertFeed` reads its `alert` lines to build the cross-workspace
    attentions feed, and crash reasons such as `{:port_exit, N}` must persist
    here for post-mortem (#708).
  - `agent.md` — human-readable markdown projection kept for direct workspace
    inspection and the Codex resume/debug contract.

  Do not filter what reaches `agent.ndjson` by event type. It is the only
  structured per-event record, so dropping "transcript" events to save a write
  silently breaks crash-reason persistence (#708) — guarded by the regression
  test in `agent_event_log_test.exs`.
  """

  require Logger

  alias Aiur.Workspace.Reconstruction

  @spec write(String.t() | nil, String.t() | nil, map()) :: :ok
  def write(_workspace, worker_host, _message) when is_binary(worker_host), do: :ok

  def write(workspace, nil, message) when is_binary(workspace) and is_map(message) do
    Reconstruction.with_log_lock(workspace, fn ->
      log_dir = Path.join(workspace, "logs")
      ndjson_path = Path.join(log_dir, "agent.ndjson")
      markdown_path = Path.join(log_dir, "agent.md")
      record = json_safe(message)
      encoded_record = Jason.encode!(record)

      with :ok <- File.mkdir_p(log_dir),
           :ok <- File.write(ndjson_path, encoded_record <> "\n", [:append]),
           :ok <- File.write(markdown_path, markdown_entry(record, encoded_record), [:append]) do
        :ok
      else
        {:error, reason} ->
          Logger.debug("Failed writing agent log workspace=#{workspace} reason=#{inspect(reason)}")
          :ok
      end
    end)
  rescue
    error ->
      Logger.debug("Failed writing agent log workspace=#{workspace} error=#{Exception.message(error)}")
      :ok
  end

  def write(_workspace, _worker_host, _message), do: :ok

  defp markdown_entry(record, encoded_record) do
    timestamp =
      record
      |> Map.get("timestamp", DateTime.utc_now())
      |> format_timestamp()

    event = Map.get(record, "event") || "event"
    summary = event_summary(record, encoded_record)

    """
    ## #{timestamp} #{event}

    #{summary}

    """
  end

  defp event_summary(record, encoded_record) do
    cond do
      is_binary(record["last_message"]) -> record["last_message"]
      is_binary(record["raw"]) -> code_block(record["raw"])
      true -> code_block(encoded_record)
    end
  end

  defp code_block(value) do
    """
    ```text
    #{value}
    ```
    """
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%{} = value), do: Map.new(value, fn {key, val} -> {json_safe_key(key), json_safe(val)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  # Tuples (e.g. a `{:port_exit, 1}` crash reason) are not JSON-encodable and
  # would otherwise make `Jason.encode!/1` raise — swallowed by the rescue in
  # `write/3`, so the crash detail never persists. Encode them as a list.
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: to_string(key)

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp format_timestamp(_timestamp), do: DateTime.utc_now() |> DateTime.to_iso8601()
end
