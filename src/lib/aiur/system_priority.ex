defmodule Aiur.SystemPriority do
  @moduledoc "Reads the daemon's Linux nice value without assuming its launch priority."

  @spec nice() :: integer() | :unavailable
  def nice do
    source = Application.get_env(:aiur, :proc_self_stat_source_override, fn -> File.read("/proc/self/stat") end)

    with {:ok, contents} when is_binary(contents) <- source.(),
         [_, fields] <- Regex.run(~r/^\d+ \(.*\) (.+)$/, String.trim(contents)),
         value when is_binary(value) <- fields |> String.split() |> Enum.at(16),
         {nice, ""} when nice >= -20 and nice <= 19 <- Integer.parse(value) do
      nice
    else
      _ -> :unavailable
    end
  end
end
