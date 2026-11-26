defmodule Aiur.BuildStamp do
  @moduledoc "Reads the release build stamp without depending on telemetry."

  @spec read(Path.t()) :: map()
  def read(path \\ Path.join(to_string(:code.root_dir()), "AIUR_BUILD_STAMP")) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> Enum.flat_map(&entry/1) |> Map.new()
      {:error, _reason} -> %{}
    end
  end

  defp entry(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key in ["source_sha", "package_version"] and value != "" -> [{key, value}]
      _other -> []
    end
  end
end
