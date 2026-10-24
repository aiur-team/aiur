defmodule Aiur.SystemCgroup do
  @moduledoc "Reads Linux cgroup v2 CPU and memory limits for container-aware admission."

  @default_mount "/sys/fs/cgroup"

  @spec cpu_quota() :: number() | :unavailable
  def cpu_quota do
    with {:ok, contents} <- read("cpu.max"),
         [quota_text, period_text] <- String.split(String.trim(contents)),
         {quota, ""} <- Integer.parse(quota_text),
         {period, ""} when period > 0 <- Integer.parse(period_text),
         true <- quota > 0 do
      quota / period
    else
      _ -> :unavailable
    end
  end

  @spec cpu_pressure() :: Aiur.SystemPressure.sample() | :unavailable
  def cpu_pressure do
    case read("cpu.pressure") do
      {:ok, contents} -> Aiur.SystemPressure.parse(contents)
      _ -> :unavailable
    end
  end

  @spec memory_max_bytes() :: pos_integer() | :unavailable
  def memory_max_bytes do
    with {:ok, maximum} <- read("memory.max"),
         {maximum, ""} when maximum > 0 <- Integer.parse(String.trim(maximum)) do
      maximum
    else
      _ -> :unavailable
    end
  end

  @spec memory() :: %{current: non_neg_integer(), inactive_file: non_neg_integer(), max: pos_integer()} | :unavailable
  def memory do
    with {:ok, current} <- read("memory.current"),
         {current, ""} when current >= 0 <- Integer.parse(String.trim(current)),
         maximum when is_integer(maximum) and maximum > 0 <- memory_max_bytes() do
      %{current: current, inactive_file: inactive_file_bytes(), max: maximum}
    else
      _ -> :unavailable
    end
  end

  defp inactive_file_bytes do
    with {:ok, contents} <- read("memory.stat"),
         line when is_binary(line) <- Enum.find(String.split(contents, "\n"), &String.starts_with?(&1, "inactive_file ")),
         ["inactive_file", value] <- String.split(line),
         {bytes, ""} when bytes >= 0 <- Integer.parse(value) do
      bytes
    else
      _ -> 0
    end
  end

  defp read(name) do
    File.read(Path.join(cgroup_root(), name))
  end

  defp cgroup_root do
    case Application.get_env(:aiur, :cgroup_root_override) do
      root when is_binary(root) -> root
      _ -> current_root()
    end
  end

  defp current_root do
    with {:ok, contents} <- File.read("/proc/self/cgroup"),
         path when is_binary(path) <- unified_path(contents),
         true <- String.starts_with?(path, "/"),
         {:ok, mountinfo} <- File.read("/proc/self/mountinfo"),
         {mount, root} when is_binary(mount) <- cgroup_mount(mountinfo) do
      relative = Path.relative_to(path, root)
      if relative == ".." or String.starts_with?(relative, "../"), do: @default_mount, else: Path.join(mount, relative)
    else
      _ -> @default_mount
    end
  end

  defp cgroup_mount(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(&cgroup_mount_line/1)
  end

  defp cgroup_mount_line(line) do
    with [before, "cgroup2 " <> _after_mount] <- String.split(line, " - ", parts: 2),
         fields = String.split(before),
         root when is_binary(root) <- Enum.at(fields, 3),
         mount when is_binary(mount) <- Enum.at(fields, 4) do
      {mount, root}
    else
      _ -> nil
    end
  end

  defp unified_path(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 3) do
        ["0", "", path] -> path
        _ -> nil
      end
    end)
  end
end
