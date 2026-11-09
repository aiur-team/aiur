defmodule Aiur.IssueLog.TimelineEventStore do
  @moduledoc false

  alias Aiur.IssueLog.Files

  @spec open(Path.t(), Path.t()) :: File.io_device() | nil
  def open(path, source) do
    :ok = File.mkdir_p(Path.dirname(path))
    if not File.exists?(path) and File.exists?(source), do: File.cp(source, path)

    case File.open(path, [:append, :utf8]) do
      {:ok, file} -> file
      {:error, _reason} -> nil
    end
  end

  @spec write(File.io_device() | nil, iodata()) :: :ok
  def write(nil, _line), do: :ok
  def write(file, line), do: Files.write_line(file, line)
  @spec close(File.io_device() | nil) :: :ok | {:error, term()}
  def close(nil), do: :ok
  def close(file), do: File.close(file)
end
