defmodule Aiur.BuildGate do
  @moduledoc """
  Shared filesystem lease metadata for agent-launched Mix verification.

  The Bash hook owns acquisition and release so a running Mix command never
  depends on an Aiur BEAM staying alive. This module supplies its environment
  and reads the advisory records for operator status.
  """

  alias Aiur.Config

  @default_timeout_seconds 900

  @type status :: %{
          enabled?: boolean(),
          capacity: non_neg_integer(),
          active: non_neg_integer(),
          queued: non_neg_integer()
        }

  @spec shell_env(keyword()) :: [{String.t(), String.t()}]
  def shell_env(opts \\ []) do
    slots = Keyword.get_lazy(opts, :slots, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)

    if gate_enabled?(slots, stagger_seconds, min_free_memory_mb) do
      [
        {"BASH_ENV", Keyword.get(opts, :hook_path, hook_path())},
        {"AIUR_BUILD_GATE_DIR", Keyword.get(opts, :gate_dir, gate_dir())},
        {"AIUR_BUILD_GATE_SLOTS", Integer.to_string(slots)},
        {"AIUR_BUILD_START_STAGGER_SECONDS", Integer.to_string(stagger_seconds)},
        {"AIUR_BUILD_GATE_TIMEOUT_SECONDS", Integer.to_string(Keyword.get(opts, :timeout_seconds, @default_timeout_seconds))}
      ] ++ memory_env(min_free_memory_mb)
    else
      []
    end
  end

  @spec gate_dir() :: Path.t()
  def gate_dir do
    case Application.get_env(:aiur, :build_gate_dir_override) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(System.user_home!(), ".aiur/build-gate")
    end
  end

  @spec hook_path() :: Path.t()
  def hook_path do
    :aiur
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("build_gate.bash")
  end

  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    capacity = Keyword.get_lazy(opts, :capacity, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)

    if gate_enabled?(capacity, stagger_seconds, min_free_memory_mb) do
      gate_dir = Keyword.get(opts, :gate_dir, gate_dir())

      %{
        enabled?: true,
        capacity: capacity,
        active: if(capacity > 0, do: active_count(gate_dir, capacity), else: 0),
        queued: queue_count(gate_dir)
      }
    else
      %{enabled?: false, capacity: 0, active: 0, queued: 0}
    end
  end

  defp active_count(gate_dir, capacity) do
    1..capacity
    |> Enum.count(fn slot ->
      gate_dir
      |> Path.join("slot-#{slot}/owner")
      |> owner_pid()
      |> owner_alive?()
    end)
  end

  defp queue_count(gate_dir) do
    gate_dir
    |> Path.join("queue")
    |> records_in()
    |> Enum.count(&owner_alive?/1)
  end

  defp records_in(path) do
    case File.ls(path) do
      {:ok, entries} -> Enum.map(entries, &owner_pid(Path.join(path, &1)))
      _ -> []
    end
  end

  defp owner_pid(path) do
    with {:ok, record} <- File.read(path),
         ["pid=" <> value | _] <- String.split(record, "\n", trim: true),
         {pid, ""} when pid > 0 <- Integer.parse(value) do
      pid
    else
      _ -> nil
    end
  end

  defp owner_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.find_executable("sh") do
      nil -> false
      shell -> match?({_output, 0}, System.cmd(shell, ["-c", "kill -0 #{pid}"], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  defp owner_alive?(_pid), do: false

  defp gate_enabled?(slots, stagger_seconds, min_free_memory_mb) do
    (is_integer(slots) and slots > 0) or
      (is_integer(stagger_seconds) and stagger_seconds > 0) or
      (is_integer(min_free_memory_mb) and min_free_memory_mb > 0)
  end

  defp memory_env(min_free_memory_mb) when is_integer(min_free_memory_mb) and min_free_memory_mb > 0,
    do: [{"AIUR_MIN_FREE_MEMORY_MB", Integer.to_string(min_free_memory_mb)}]

  defp memory_env(_min_free_memory_mb), do: []
end
