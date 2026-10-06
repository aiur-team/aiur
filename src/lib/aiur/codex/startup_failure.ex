defmodule Aiur.Codex.StartupFailure do
  @moduledoc """
  Durable, bounded evidence for a Codex process that exits before handshake.

  This file belongs to the daemon's run log, so it exists even when the agent
  workspace transcript has not been created. JSON-RPC frames are never copied.
  """

  require Logger
  alias Aiur.Config.Paths

  @max_excerpt_chars 250

  @spec record(String.t() | nil, String.t() | nil, integer(), String.t()) :: :ok
  def record(identifier, attempt_id, status, output)
      when is_binary(identifier) and is_integer(status) and is_binary(output) do
    record_with_writer(identifier, attempt_id, status, output, &File.write(&1, &2, [:append]))
  end

  def record(_identifier, _attempt_id, _status, _output), do: :ok

  @doc false
  @spec record_with_writer(String.t() | nil, String.t() | nil, integer(), String.t(), (String.t(), String.t() -> :ok | {:error, term()})) :: :ok
  def record_with_writer(identifier, attempt_id, status, output, writer)
      when is_binary(identifier) and is_integer(status) and is_binary(output) and is_function(writer, 2) do
    record = %{
      ticket: identifier,
      attempt_id: attempt_id,
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      reason_class: "port_exit",
      exit_status: status,
      diagnostic: safe_excerpt(output)
    }

    path = Path.join(Paths.log_root_dir(), "#{Paths.repo_name()}.#{Paths.sanitize(identifier)}.startup-failures.ndjson")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600),
         :ok <- writer.(path, Jason.encode!(record) <> "\n") do
      :ok
    else
      {:error, reason} -> Logger.warning("Could not persist Codex startup failure for #{identifier}: #{inspect(reason)}")
    end

    :ok
  end

  def record_with_writer(_identifier, _attempt_id, _status, _output, _writer), do: :ok

  @doc false
  @spec safe_excerpt(String.t()) :: String.t()
  def safe_excerpt(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&protocol_frame?/1)
    |> Enum.map(&redact_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-4)
    |> Enum.join("\n")
    |> String.slice(0, @max_excerpt_chars)
  rescue
    _ -> "[diagnostic unavailable]"
  end

  defp protocol_frame?(line) do
    trimmed =
      line
      |> String.trim_leading()
      |> String.replace(~r/\A(?:\e\[[0-9;]*m\s*)+/, "")

    String.starts_with?(trimmed, ["{", "["])
  end

  defp redact_line(line) do
    line = String.trim(line)

    if String.match?(line, ~r/(authorization|bearer|password|secret|token|invite|grant|credential|api[\s_-]*key|session[_-]?key|cookie)/i) do
      "[redacted sensitive output]"
    else
      line
      |> String.replace(~r{https?://\S+}, "[redacted URL]")
      |> String.replace(~r/[A-Za-z0-9+_=-]{40,}/, "[redacted value]")
    end
  end
end
