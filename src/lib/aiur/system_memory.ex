defmodule Aiur.SystemMemory do
  @moduledoc """
  Reads Linux `MemAvailable` for host memory admission decisions.

  `/proc/meminfo` reports values in kB; this module exposes whole MB, rounded
  down so admission never overstates available headroom. Missing or malformed
  data returns `:unavailable`, allowing callers to preserve Aiur's fail-open
  resource-gate behavior on non-Linux development hosts.
  """

  @kilobytes_per_megabyte 1_024

  @doc """
  Available host memory in whole MB, or `:unavailable` when it cannot be read.
  """
  @spec available_mb() :: non_neg_integer() | :unavailable
  def available_mb do
    case meminfo_source().() do
      {:ok, contents} -> parse_available_mb(contents)
      _other -> :unavailable
    end
  end

  defp parse_available_mb(contents) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.find_value(:unavailable, &available_mb_from_line/1)
  end

  defp parse_available_mb(_contents), do: :unavailable

  defp available_mb_from_line(line) do
    case String.split(line) do
      ["MemAvailable:", value, "kB"] -> parse_kilobytes(value)
      _other -> nil
    end
  end

  defp parse_kilobytes(value) do
    case Integer.parse(value) do
      {kilobytes, ""} when kilobytes >= 0 -> div(kilobytes, @kilobytes_per_megabyte)
      _other -> nil
    end
  end

  defp meminfo_source do
    Application.get_env(:aiur, :meminfo_source_override, fn -> File.read("/proc/meminfo") end)
  end
end
