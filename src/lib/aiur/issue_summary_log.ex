defmodule Aiur.IssueSummaryLog do
  @moduledoc """
  Capped per-issue progress summary log writer.

  Summary logs sit beside the raw per-issue logs and intentionally keep a
  simpler shape: one dated bullet per line, deduplicated by exact line.
  """

  alias Aiur.AgentEvents
  alias Aiur.Config.Paths

  @default_max_lines 200

  @spec log_path(AgentEvents.agent_identifier()) :: String.t()
  def log_path(identifier) when is_binary(identifier) do
    Path.join(log_root_dir(), "#{repo_name()}.#{sanitize(identifier)}.summary.log")
  end

  @spec append_once(AgentEvents.agent_identifier(), String.t(), keyword()) :: :ok
  def append_once(identifier, text, opts \\ []) when is_binary(identifier) and is_binary(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if text == "" do
      :ok
    else
      path = log_path(identifier)
      :ok = File.mkdir_p(Path.dirname(path))

      line = "#{date(opts)} - #{text}\n"

      unless existing_line?(path, line) do
        File.write!(path, line, [:append])
        cap_file(path, Keyword.get(opts, :max_lines, max_lines()))
      end

      :ok
    end
  end

  @spec max_lines() :: pos_integer()
  def max_lines do
    case Application.get_env(:aiur, :issue_summary_log_max_lines, @default_max_lines) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_lines
    end
  end

  defp existing_line?(path, line) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: false) |> Enum.map(&(&1 <> "\n"))
        line in lines

      _ ->
        false
    end
  end

  defp cap_file(_path, max_lines) when not is_integer(max_lines), do: :ok
  defp cap_file(_path, max_lines) when max_lines <= 0, do: :ok

  defp cap_file(path, max_lines) do
    lines =
      path
      |> File.read!()
      |> String.split("\n", trim: true)

    if length(lines) > max_lines do
      kept = lines |> Enum.take(-max_lines) |> Enum.join("\n")
      File.write!(path, kept <> "\n")
    end

    :ok
  end

  defp date(opts) do
    case Keyword.get(opts, :timestamp) do
      %DateTime{} = ts -> ts |> DateTime.to_date() |> Date.to_iso8601()
      %Date{} = date -> Date.to_iso8601(date)
      nil -> Date.utc_today() |> Date.to_iso8601()
    end
  end

  defp log_root_dir, do: Paths.log_root_dir()
  defp repo_name, do: Paths.repo_name()
  defp sanitize(identifier), do: Paths.sanitize(identifier)
end
