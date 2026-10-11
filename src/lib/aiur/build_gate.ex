defmodule Aiur.BuildGate do
  @moduledoc """
  Shared filesystem lease metadata for agent-launched Mix verification.

  The Bash hook owns acquisition and release so a running Mix command never
  depends on an Aiur BEAM staying alive. This module supplies its environment
  and reads the advisory records for Executor status.
  """

  require Logger

  alias Aiur.BuildGate.{PidStatus, Status}
  alias Aiur.Config
  alias Aiur.PathSafety

  @default_timeout_seconds 900
  @recovery Status.recovery()

  @type status :: %{
          required(:enabled?) => boolean(),
          required(:capacity) => non_neg_integer(),
          required(:active) => non_neg_integer(),
          required(:queued) => non_neg_integer(),
          required(:oldest_wait_seconds) => non_neg_integer() | nil,
          optional(:holders) => [holder()],
          optional(:timeouts) => [timeout_record()],
          optional(:retain_seconds) => non_neg_integer(),
          optional(:degraded?) => boolean(),
          optional(:issues) => [map()]
        }

  @type holder :: %{
          required(:kind) => :slot | :queue,
          required(:slot) => pos_integer() | nil,
          required(:pid) => pos_integer() | nil,
          required(:pgid) => pos_integer() | nil,
          required(:holder_pid) => pos_integer() | nil,
          required(:command_pgid) => pos_integer() | nil,
          required(:command_alive?) => boolean() | nil,
          required(:phase) => String.t() | nil,
          required(:command) => String.t() | nil,
          required(:started_at) => pos_integer() | nil,
          required(:held_for_seconds) => non_neg_integer() | nil
        }

  @type timeout_record :: %{
          required(:slot) => pos_integer() | nil,
          required(:command) => String.t() | nil,
          required(:held_for_seconds) => non_neg_integer() | nil,
          required(:reason) => String.t() | nil,
          required(:path) => Path.t()
        }

  @spec shell_env(keyword()) :: [{String.t(), String.t()}]
  def shell_env(opts \\ []) do
    slots = Keyword.get_lazy(opts, :slots, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)
    max_hold_seconds = Keyword.get_lazy(opts, :max_hold_seconds, &Config.build_gate_max_hold_seconds/0)
    retain_seconds = Keyword.get_lazy(opts, :retain_seconds, &Config.build_gate_retain_seconds/0)

    if enabled?(slots: slots, stagger_seconds: stagger_seconds, min_free_memory_mb: min_free_memory_mb) do
      gate_dir = Keyword.get(opts, :gate_dir, gate_dir())
      lock_dir = Keyword.get(opts, :lock_dir, lock_dir(gate_dir))

      # AgentEnvironment builds this environment on the host for every backend.
      # Prepare immutable lock inodes there, before a sandbox receives only the
      # writable metadata root; preparation failures remain fail-closed in the shell hook.
      _ = prepare_lock_namespace(lock_dir, slots)

      [
        {"BASH_ENV", Keyword.get(opts, :hook_path, hook_path())},
        {"AIUR_BUILD_GATE_DIR", gate_dir},
        {"AIUR_BUILD_GATE_LOCK_DIR", lock_dir},
        {"AIUR_BUILD_GATE_SLOTS", Integer.to_string(slots)},
        {"AIUR_BUILD_NICE", Integer.to_string(Keyword.get_lazy(opts, :nice, fn -> Config.settings!().agent.build_nice end))},
        {"AIUR_BUILD_START_STAGGER_SECONDS", Integer.to_string(stagger_seconds)},
        {"AIUR_BUILD_GATE_TIMEOUT_SECONDS", Integer.to_string(Keyword.get(opts, :timeout_seconds, @default_timeout_seconds))},
        {"AIUR_BUILD_GATE_MAX_HOLD_SECONDS", Integer.to_string(max_hold_seconds)},
        {"AIUR_BUILD_GATE_RETAIN_SECONDS", Integer.to_string(retain_seconds)}
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

  @doc "Host-owned lock namespace kept outside the sandbox-writable gate root."
  @spec lock_dir(Path.t()) :: Path.t()
  def lock_dir(gate_dir \\ gate_dir()) when is_binary(gate_dir) do
    Path.expand(gate_dir) <> ".locks"
  end

  @spec hook_path() :: Path.t()
  def hook_path do
    :aiur
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("build_gate.bash")
  end

  @doc "Whether any local build admission mode requires the shared gate."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    slots = Keyword.get_lazy(opts, :slots, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)

    (is_integer(slots) and slots > 0) or
      (is_integer(stagger_seconds) and stagger_seconds > 0) or
      (is_integer(min_free_memory_mb) and min_free_memory_mb > 0)
  end

  @doc "Creates, canonicalizes, and verifies the local shared gate directory."
  @spec prepare_writable_root(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def prepare_writable_root(opts \\ []) do
    gate_dir = opts |> Keyword.get(:gate_dir, gate_dir()) |> Path.expand()
    lock_dir = opts |> Keyword.get(:lock_dir, lock_dir(gate_dir)) |> Path.expand()
    slots = Keyword.get_lazy(opts, :slots, &Config.max_concurrent_builds/0)
    writable_roots = Keyword.get(opts, :writable_roots, [])

    with :ok <- prepare_directory(gate_dir),
         {:ok, canonical_gate_dir} <- canonicalize_gate_dir(gate_dir),
         :ok <- probe_writable(canonical_gate_dir),
         {:ok, canonical_lock_dir} <- prepare_lock_namespace(lock_dir, slots),
         {:ok, canonical_writable_roots} <- canonicalize_writable_roots(writable_roots),
         :ok <-
           validate_lock_namespace(
             canonical_lock_dir,
             [canonical_gate_dir | canonical_writable_roots]
           ) do
      {:ok, canonical_gate_dir}
    end
  end

  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    capacity = Keyword.get_lazy(opts, :capacity, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)

    if enabled?(slots: capacity, stagger_seconds: stagger_seconds, min_free_memory_mb: min_free_memory_mb) do
      gate_dir = Keyword.get(opts, :gate_dir, gate_dir())
      retain_seconds = Keyword.get_lazy(opts, :retain_seconds, &Config.build_gate_retain_seconds/0)

      result =
        if linux_lock_strategy?(opts) do
          Status.linux(gate_dir, Keyword.get(opts, :lock_dir, lock_dir(gate_dir)), capacity)
          |> Status.with_oldest_wait()
        else
          PidStatus.read(gate_dir, capacity)
          |> Status.with_oldest_wait()
        end

      # The effective post-command retain window is part of the status surface
      # so the gate's throughput trade is measurable at runtime, not inferred
      # from `fuser` (#2398).
      Map.put(result, :retain_seconds, retain_seconds)
    else
      %{enabled?: false, capacity: 0, active: 0, queued: 0, oldest_wait_seconds: 0, holders: []}
    end
  end

  defp linux_lock_strategy?(opts) do
    case Keyword.get(opts, :strategy, :auto) do
      :linux_lock -> true
      :pid -> false
      :auto -> match?({:unix, :linux}, :os.type())
    end
  end

  defp prepare_directory(gate_dir) do
    case File.mkdir_p(gate_dir) do
      :ok -> :ok
      {:error, reason} -> unavailable(gate_dir, :create_directory, reason)
    end
  end

  defp prepare_lock_namespace(lock_dir, slots) do
    with :ok <- prepare_directory(lock_dir),
         {:ok, canonical_lock_dir} <- canonicalize_gate_dir(lock_dir),
         :ok <- probe_writable(canonical_lock_dir),
         :ok <- ensure_lock_files(canonical_lock_dir, slots) do
      {:ok, canonical_lock_dir}
    end
  end

  defp ensure_lock_files(lock_dir, slots) do
    slot_paths =
      if is_integer(slots) and slots > 0 do
        Enum.map(1..slots, &Path.join(lock_dir, "slot-#{&1}.lock"))
      else
        []
      end

    Enum.reduce_while([Path.join(lock_dir, "phase-start.lock") | slot_paths], :ok, fn path, :ok ->
      case ensure_regular_lock_file(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, unavailable(path, :prepare_lock_file, reason)}
      end
    end)
  end

  defp ensure_regular_lock_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_regular, type}}

      {:error, :enoent} ->
        case File.open(path, [:write, :exclusive]) do
          {:ok, io_device} -> File.close(io_device)
          {:error, :eexist} -> ensure_regular_lock_file(path)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonicalize_writable_roots(roots) when is_list(roots) do
    {canonical_roots, dropped} =
      Enum.reduce(roots, {[], []}, fn root, {good, bad} ->
        case root |> Path.expand() |> PathSafety.canonicalize() do
          {:ok, canonical_root} -> {[canonical_root | good], bad}
          {:error, reason} -> {good, [{root, reason} | bad]}
        end
      end)

    Enum.each(dropped, fn {root, reason} ->
      Logger.warning("build_gate skipped_unresolvable_writable_root path=#{root} reason=#{inspect(reason)}")
    end)

    if canonical_roots == [] and dropped != [] do
      {first_root, first_reason} = List.last(dropped)
      unavailable(first_root, :canonicalize_writable_root, first_reason)
    else
      {:ok, canonical_roots}
    end
  end

  defp canonicalize_writable_roots(roots),
    do: unavailable(inspect(roots), :canonicalize_writable_roots, :invalid_writable_roots)

  defp validate_lock_namespace(lock_dir, writable_roots) do
    case Enum.find(writable_roots, &paths_overlap?(&1, lock_dir)) do
      nil -> :ok
      writable_root -> unavailable(lock_dir, :separate_lock_namespace, {:overlaps_writable_root, writable_root})
    end
  end

  defp paths_overlap?(left, right) do
    left == right or
      String.starts_with?(left <> "/", right <> "/") or
      String.starts_with?(right <> "/", left <> "/")
  end

  defp canonicalize_gate_dir(gate_dir) do
    case PathSafety.canonicalize(gate_dir) do
      {:ok, canonical_gate_dir} -> {:ok, canonical_gate_dir}
      {:error, reason} -> unavailable(gate_dir, :canonicalize, reason)
    end
  end

  defp probe_writable(gate_dir) do
    probe_path =
      Path.join(
        gate_dir,
        ".aiur-write-probe-#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.open(probe_path, [:write, :exclusive]) do
      {:ok, io_device} ->
        File.close(io_device)

        case File.rm(probe_path) do
          :ok -> :ok
          {:error, reason} -> unavailable(gate_dir, :remove_probe, reason)
        end

      {:error, reason} ->
        unavailable(gate_dir, :write_probe, reason)
    end
  end

  defp unavailable(path, operation, reason) do
    {:error, {:build_gate_unavailable, %{path: path, operation: operation, reason: reason, recovery: @recovery}}}
  end

  defp memory_env(min_free_memory_mb) when is_integer(min_free_memory_mb) and min_free_memory_mb > 0,
    do: [{"AIUR_MIN_FREE_MEMORY_MB", Integer.to_string(min_free_memory_mb)}]

  defp memory_env(_min_free_memory_mb), do: []
end
