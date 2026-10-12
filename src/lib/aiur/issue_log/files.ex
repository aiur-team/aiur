defmodule Aiur.IssueLog.Files do
  @moduledoc false

  require Logger

  @spec write_line(File.io_device(), iodata()) :: :ok
  def write_line(file, line) do
    IO.write(file, line)
  rescue
    _ -> :ok
  end

  @spec open_log_files(String.t(), String.t(), String.t()) :: {:ok, File.io_device(), File.io_device(), File.io_device()} | {:error, term()}
  def open_log_files(path, event_path, transcript_path) do
    with {:ok, file} <- open_primary_log(path),
         {:ok, event_file} <- open_event_log(event_path, file),
         {:ok, transcript_file} <- open_transcript_log(transcript_path, file, event_file) do
      {:ok, file, event_file, transcript_file}
    end
  end

  defp open_primary_log(path) do
    case File.open(path, [:append, :utf8]) do
      {:ok, file} ->
        {:ok, file}

      {:error, reason} ->
        Logger.warning("IssueLog open failed path=#{path} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp open_event_log(path, file) do
    case File.open(path, [:append, :utf8]) do
      {:ok, event_file} ->
        {:ok, event_file}

      {:error, reason} ->
        _ = File.close(file)
        Logger.warning("IssueLog event open failed path=#{path} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp open_transcript_log(path, file, event_file) do
    case File.open(path, [:append, :utf8]) do
      {:ok, transcript_file} ->
        {:ok, transcript_file}

      {:error, reason} ->
        _ = File.close(event_file)
        _ = File.close(file)
        Logger.warning("IssueLog transcript open failed path=#{path} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end
end
