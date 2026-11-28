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
      %{current: current, inactive_file: inactive_file_bytes(cgroup_root()) || 0, max: maximum}
    else
      _ -> :unavailable
    end
  end

  @doc "Capacity signal from the Aiur slice, or the daemon's cgroup when no slice is present."
  @spec dispatch_headroom(number(), number()) :: :healthy | :pressure | :unknown
  def dispatch_headroom(cpu_target, memory_threshold) do
    current = cgroup_root()
    parents = ancestors(current)
    slice = Enum.find(parents, &(Path.basename(&1) == "aiur.slice")) || find_managed_slice(parents)
    root = slice || current

    if is_nil(slice) and unconstrained_root?(root), do: :healthy, else: resource_headroom(root, cpu_target, memory_threshold, not is_nil(slice))
  end

  defp find_managed_slice(parents) do
    if is_nil(Application.get_env(:aiur, :cgroup_root_override)) do
      parents
      |> Enum.take_while(&(&1 != "/"))
      |> Enum.map(&Path.join(&1, "aiur.slice"))
      |> Enum.find(&File.dir?/1)
    end
  end

  # The cgroup v2 hierarchy root has no CPU or memory controller limits.
  defp unconstrained_root?(@default_mount),
    do: not File.exists?(Path.join(@default_mount, "cgroup.type")) and match?({:ok, _}, read("cgroup.controllers", @default_mount))

  defp unconstrained_root?(_root), do: false

  defp resource_headroom(root, cpu_target, memory_threshold, slice?) do
    cpu = cpu_headroom(root, cpu_target, slice?)
    memory = memory_headroom(root, memory_threshold)

    cond do
      :pressure in [cpu, memory] -> :pressure
      :unknown in [cpu, memory] -> :unknown
      true -> :healthy
    end
  end

  defp ancestors(path) do
    parent = Path.dirname(path)
    if path == parent, do: [path], else: [path | ancestors(parent)]
  end

  defp cpu_headroom(root, target, slice?) do
    with {:ok, quota} <- read("cpu.max", root),
         [limit, period] <- String.split(quota),
         true <- limit == "max" or is_integer(positive_limit(limit)),
         true <- is_integer(positive_limit(period)) do
      if limit == "max" and not slice?, do: :healthy, else: cpu_pressure_headroom(root, target)
    else
      _ -> :unknown
    end
  end

  defp cpu_pressure_headroom(root, target) do
    with {:ok, contents} <- read("cpu.pressure", root),
         %{avg10: avg10} <- Aiur.SystemPressure.parse(contents) do
      if avg10 > target, do: :pressure, else: :healthy
    else
      _ -> :unknown
    end
  end

  defp memory_headroom(root, threshold) do
    case {read_limit(root, "memory.high"), read_limit(root, "memory.max")} do
      {:unlimited, :unlimited} -> :healthy
      {:unknown, _} -> :unknown
      {_, :unknown} -> :unknown
      {high, maximum} -> memory_pressure_headroom(root, Enum.min(Enum.filter([high, maximum], &is_integer/1)), threshold)
    end
  end

  defp memory_pressure_headroom(root, limit, threshold) do
    with {:ok, current} <- read("memory.current", root),
         {bytes, ""} when bytes >= 0 <- Integer.parse(String.trim(current)),
         inactive when is_integer(inactive) <- inactive_file_bytes(root) do
      if max(0, bytes - inactive) > limit * threshold, do: :pressure, else: :healthy
    else
      _ -> :unknown
    end
  end

  defp read_limit(root, name) do
    case read(name, root) do
      {:ok, value} -> parse_limit(String.trim(value))
      _ -> :unknown
    end
  end

  defp parse_limit("max"), do: :unlimited

  defp parse_limit(limit) do
    case Integer.parse(limit) do
      {value, ""} when value >= 0 -> value
      _ -> :unknown
    end
  end

  defp positive_limit(text) do
    case Integer.parse(text) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp inactive_file_bytes(root) do
    with {:ok, contents} <- read("memory.stat", root),
         line when is_binary(line) <- Enum.find(String.split(contents, "\n"), &String.starts_with?(&1, "inactive_file ")),
         ["inactive_file", value] <- String.split(line),
         {bytes, ""} when bytes >= 0 <- Integer.parse(value) do
      bytes
    else
      _ -> nil
    end
  end

  defp read(name, root \\ cgroup_root()) do
    case :file.open(Path.join(root, name), [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          read_chunks(fd, [])
        after
          :file.close(fd)
        end

      error ->
        error
    end
  end

  defp read_chunks(fd, chunks) do
    case :file.read(fd, 4_096) do
      {:ok, chunk} -> read_chunks(fd, [chunk | chunks])
      :eof -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp cgroup_root do
    case Application.get_env(:aiur, :cgroup_root_override) do
      root when is_binary(root) -> root
      _ -> current_root()
    end
  end

  defp current_root, do: root(&discover_root/0)

  @doc false
  @spec root((-> Path.t())) :: Path.t()
  def root(discover) do
    key = {__MODULE__, :root}

    case :persistent_term.get(key, nil) do
      nil ->
        root = discover.()
        :persistent_term.put(key, root)
        root

      root ->
        root
    end
  end

  defp discover_root do
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
