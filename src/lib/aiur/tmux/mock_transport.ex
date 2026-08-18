defmodule Aiur.Tmux.MockTransport do
  @moduledoc """
  Test seam for Aiur.Tmux. Replaces the shell exec path in tests by routing
  tmux command strings to a designated test-process inbox and blocking on the
  response.
  """

  @doc """
  Runs the blocking selective receive in the caller's process (the `Aiur.Tmux`
  GenServer); tests inject `{:tmux_mock_data, chunk}` to that pid. Pass
  `:infinity` when the test itself drives every response and should not race a
  transport deadline.
  """
  @spec request(pid(), String.t(), timeout()) :: {:ok, [String.t()]} | {:error, term()}
  def request(pid, command, response_timeout \\ 1_000) do
    send(pid, {:tmux_mock_out, command})
    receive_mock_response(response_timeout)
  end

  defp receive_mock_response(response_timeout) do
    receive do
      {:tmux_mock_data, "%begin " <> _ = chunk} -> parse_mock_response(chunk)
    after
      response_timeout -> {:error, :no_mock_response}
    end
  end

  defp parse_mock_response(chunk) do
    lines = String.split(chunk, "\n", trim: true)

    body =
      Enum.reduce(lines, [], fn line, acc ->
        cond do
          String.starts_with?(line, "%begin") -> acc
          String.starts_with?(line, "%end") -> acc
          String.starts_with?(line, "%error") -> acc
          true -> [line | acc]
        end
      end)
      |> Enum.reverse()

    if Enum.any?(lines, &String.starts_with?(&1, "%error")) do
      {:error, body}
    else
      {:ok, body}
    end
  end
end
