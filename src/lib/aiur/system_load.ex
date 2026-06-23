defmodule Aiur.SystemLoad do
  @moduledoc """
  Reads the host's 1-minute load average so the orchestrator can hold new agent
  dispatch when the box is already saturated (#465).

  Linux-only via `/proc/loadavg`. Anywhere the file is absent or unreadable
  (e.g. a macOS dev box) it returns `:unavailable` so the load gate degrades
  open — no throttling rather than a spurious hold. The source is injectable via
  the `:loadavg_source_override` app env so tests can simulate any load without
  touching the real filesystem, following the app-env override convention used
  elsewhere (e.g. `Aiur.Os`).
  """

  @doc """
  The 1-minute load average as a float, or `:unavailable` when it cannot be read
  (non-Linux host, missing `/proc/loadavg`, or unparseable contents).
  """
  @spec avg1() :: float() | :unavailable
  def avg1 do
    case loadavg_source().() do
      {:ok, contents} -> parse_avg1(contents)
      _other -> :unavailable
    end
  end

  defp parse_avg1(contents) do
    case contents |> String.trim_leading() |> Float.parse() do
      {value, _rest} -> value
      :error -> :unavailable
    end
  end

  defp loadavg_source do
    Application.get_env(:aiur, :loadavg_source_override, fn -> File.read("/proc/loadavg") end)
  end
end
