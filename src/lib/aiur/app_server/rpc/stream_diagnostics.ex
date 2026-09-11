defmodule Aiur.AppServer.Rpc.StreamDiagnostics do
  @moduledoc """
  Bounded per-port ring of the most recent non-JSON provider stream lines.

  App-server ports run with `stderr_to_stdout`, so a provider CLI that refuses a
  turn by printing a message and exiting writes that message onto the same port
  as the JSON-RPC frames. The transport logs those lines and drops them, which
  is why the #2607 session-limit refusal reached the orchestrator as a bare
  `{:turn_failed, %{"error" => "Error: claude exited with code 1"}}` with the
  actual cause nowhere in the payload.

  Retaining the last few lines gives the failure paths something to classify.
  The ring is per-port process state (the same convention
  `Aiur.AppServer.Rpc.SensitiveResponses` uses) because the RPC await loop and
  the turn loop both run in the agent runner's own process. Lines are trimmed
  and truncated; sensitive-response output is never recorded.
  """

  @key {__MODULE__, :recent_lines}

  # Enough to span a short refusal banner plus its surrounding noise, small
  # enough that the retained text stays cheap to hold and to scan.
  @max_lines 20
  @max_line_length 1_000

  @spec record(port(), binary()) :: :ok
  def record(port, line) when is_port(port) and is_binary(line) do
    case normalize(line) do
      "" -> :ok
      text -> put_lines(port, Enum.take(lines(port) ++ [text], -@max_lines))
    end
  end

  def record(_port, _line), do: :ok

  @doc """
  The retained lines for `port`, oldest first, joined by newlines. Returns `""`
  when nothing non-JSON has been seen.
  """
  @spec recent_text(port()) :: String.t()
  def recent_text(port) when is_port(port), do: port |> lines() |> Enum.join("\n")
  def recent_text(_port), do: ""

  @spec clear(port()) :: :ok
  def clear(port) when is_port(port) do
    Process.delete({@key, port})
    :ok
  end

  def clear(_port), do: :ok

  defp lines(port), do: Process.get({@key, port}, [])

  defp put_lines(port, lines) do
    Process.put({@key, port}, lines)
    :ok
  end

  defp normalize(line), do: line |> String.trim() |> String.slice(0, @max_line_length)
end
