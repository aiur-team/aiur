defmodule Aiur.BuildGate do
  @moduledoc """
  Shared filesystem lease metadata for agent-launched Mix verification.

  The Bash hook owns acquisition and release so a running Mix command never
  depends on an Aiur BEAM staying alive. This module supplies its environment
  and reads the advisory records for Executor status.
  """

  alias Aiur.Config
  alias Aiur.PathSafety

  @default_timeout_seconds 900
  @recovery "repair the configured build-gate directory and retry, or explicitly disable the gate with agent.max_concurrent_builds: 0"

  @type status :: %{
          required(:enabled?) => boolean(),
          required(:capacity) => non_neg_integer(),
          required(:active) => non_neg_integer(),
          required(:queued) => non_neg_integer(),
          optional(:degraded?) => boolean(),
          optional(:issues) => [map()]
        }

  @spec shell_env(keyword()) :: [{String.t(), String.t()}]
  def shell_env(opts \\ []) do
    slots = Keyword.get_lazy(opts, :slots, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)

    if enabled?(slots: slots, stagger_seconds: stagger_seconds, min_free_memory_mb: min_free_memory_mb) do
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

    with :ok <- prepare_directory(gate_dir),
         {:ok, canonical_gate_dir} <- canonicalize_gate_dir(gate_dir),
         :ok <- probe_writable(canonical_gate_dir) do
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

      if linux_lock_strategy?(opts) do
        linux_status(gate_dir, capacity)
      else
        %{
          enabled?: true,
          capacity: capacity,
          active: if(capacity > 0, do: active_count(gate_dir, capacity), else: 0),
          queued: queue_count(gate_dir)
        }
      end
    else
      %{enabled?: false, capacity: 0, active: 0, queued: 0}
    end
  end

  defp linux_status(gate_dir, capacity) do
    base = %{enabled?: true, capacity: capacity, active: 0, queued: 0}

    cond do
      not File.exists?(gate_dir) ->
        base

      not File.dir?(gate_dir) ->
        degraded(base, [status_issue(:gate_directory_invalid, gate_dir)])

      true ->
        do_linux_status(base, gate_dir, capacity)
    end
  end

  defp do_linux_status(base, gate_dir, capacity) do
    with flock when is_binary(flock) <- System.find_executable("flock"),
         shell when is_binary(shell) <- System.find_executable("sh"),
         :ok <- File.mkdir_p(Path.join(gate_dir, "locks")) do
      {active, slot_issues} = linux_active_count(gate_dir, capacity, shell, flock)
      {queued, queue_issues} = linux_queue_count(gate_dir, shell, flock)
      phase_issues = cleanup_phase_metadata(gate_dir, shell, flock)
      issues = legacy_issues(gate_dir) ++ slot_issues ++ queue_issues ++ phase_issues

      base
      |> Map.merge(%{active: active, queued: queued})
      |> degraded(issues)
    else
      nil -> degraded(base, [status_issue(:flock_unavailable, gate_dir)])
      {:error, reason} -> degraded(base, [status_issue(:gate_directory_unwritable, gate_dir, reason)])
    end
  end

  defp linux_active_count(_gate_dir, capacity, _shell, _flock) when capacity <= 0, do: {0, []}

  defp linux_active_count(gate_dir, capacity, shell, flock) do
    Enum.reduce(1..capacity, {0, []}, fn slot, {active, issues} ->
      lock_path = Path.join(gate_dir, "locks/slot-#{slot}.lock")
      owner_path = Path.join(gate_dir, "slot-#{slot}.owner")

      case probe_lock(lock_path, owner_path, shell, flock) do
        :locked -> {active + 1, maybe_metadata_issue(issues, owner_path)}
        :unlocked -> {active, issues}
        {:error, reason} -> {active, [status_issue(:lock_probe_failed, lock_path, reason) | issues]}
      end
    end)
    |> then(fn {active, issues} -> {active, Enum.reverse(issues)} end)
  end

  defp linux_queue_count(gate_dir, shell, flock) do
    queue_dir = Path.join(gate_dir, "queue")

    case File.ls(queue_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "lease-v2-"))
        |> Enum.reduce({0, []}, &count_queue_entry(&1, &2, queue_dir, shell, flock))
        |> then(fn {queued, issues} -> {queued, Enum.reverse(issues)} end)

      {:error, :enoent} ->
        {0, []}

      {:error, reason} ->
        {0, [status_issue(:queue_unreadable, queue_dir, reason)]}
    end
  end

  defp count_queue_entry(entry, {queued, issues}, queue_dir, shell, flock) do
    path = Path.join(queue_dir, entry)

    case probe_lock(path, path, shell, flock) do
      :locked -> {queued + 1, maybe_metadata_issue(issues, path)}
      :unlocked -> {queued, issues}
      {:error, reason} -> {queued, [status_issue(:lock_probe_failed, path, reason) | issues]}
    end
  end

  defp cleanup_phase_metadata(gate_dir, shell, flock) do
    lock_path = Path.join(gate_dir, "locks/phase-start.lock")
    owner_path = Path.join(gate_dir, "phase-start.owner")

    if File.exists?(lock_path) or File.exists?(owner_path) do
      case probe_lock(lock_path, owner_path, shell, flock) do
        :locked -> maybe_metadata_issue([], owner_path)
        :unlocked -> []
        {:error, reason} -> [status_issue(:lock_probe_failed, lock_path, reason)]
      end
    else
      []
    end
  end

  defp probe_lock(lock_path, cleanup_path, shell, flock) do
    script = ~S"""
    exec 9<>"$1" || exit 76
    "$2" -n -E 75 9 || exit $?
    rm -f -- "$3" || exit 77
    """

    case System.cmd(shell, ["-c", script, "aiur-build-gate-status", lock_path, flock, cleanup_path], stderr_to_stdout: true) do
      {_output, 0} -> :unlocked
      {_output, 75} -> :locked
      {output, status} -> {:error, %{status: status, output: String.trim(output)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp maybe_metadata_issue(issues, path) do
    case File.read(path) do
      {:ok, "version=2\n" <> _rest} -> issues
      {:error, :enoent} -> issues
      {:ok, _contents} -> [status_issue(:invalid_metadata, path) | issues]
      {:error, reason} -> [status_issue(:metadata_unreadable, path, reason) | issues]
    end
  end

  defp legacy_issues(gate_dir) do
    gate_dir
    |> legacy_paths()
    |> Enum.map(&status_issue(:legacy_state, &1))
  end

  defp legacy_paths(gate_dir) do
    root_paths =
      case File.ls(gate_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&legacy_root_entry?/1)
          |> Enum.map(&Path.join(gate_dir, &1))

        _ ->
          []
      end

    queue_dir = Path.join(gate_dir, "queue")

    queue_paths =
      case File.ls(queue_dir) do
        {:ok, entries} ->
          entries
          |> Enum.reject(&String.starts_with?(&1, "lease-v2-"))
          |> Enum.map(&Path.join(queue_dir, &1))

        _ ->
          []
      end

    Enum.sort(root_paths ++ queue_paths)
  end

  defp legacy_root_entry?("phase-start.lock"), do: true
  defp legacy_root_entry?(entry), do: Regex.match?(~r/^slot-[1-9][0-9]*$/, entry)

  defp status_issue(reason, path, detail \\ nil) do
    %{reason: reason, path: path, detail: detail, recovery: @recovery}
  end

  defp degraded(status, []), do: status
  defp degraded(status, issues), do: Map.merge(status, %{degraded?: true, issues: issues})

  defp linux_lock_strategy?(opts) do
    case Keyword.get(opts, :strategy, :auto) do
      :linux_lock -> true
      :pid -> false
      :auto -> match?({:unix, :linux}, :os.type())
    end
  end

  defp active_count(gate_dir, capacity) do
    1..capacity
    |> Enum.count(fn slot ->
      slot_path = Path.join(gate_dir, "slot-#{slot}")

      slot_path
      |> slot_owner_path()
      |> owner_record_alive?()
    end)
  end

  defp slot_owner_path(slot_path) do
    if File.dir?(slot_path), do: Path.join(slot_path, "owner"), else: slot_path
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

  defp owner_pgid(path) do
    with {:ok, record} <- File.read(path),
         "pgid=" <> value <- Enum.find(String.split(record, "\n", trim: true), &String.starts_with?(&1, "pgid=")),
         {pgid, ""} when pgid > 0 <- Integer.parse(value) do
      pgid
    else
      _ -> nil
    end
  end

  defp owner_record_alive?(path) do
    owner_alive?(owner_pid(path)) or process_group_alive?(owner_pgid(path))
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

  defp process_group_alive?(pgid) when is_integer(pgid) and pgid > 0 do
    case System.find_executable("sh") do
      nil -> false
      shell -> match?({_output, 0}, System.cmd(shell, ["-c", "kill -0 -#{pgid}"], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  defp process_group_alive?(_pgid), do: false

  defp prepare_directory(gate_dir) do
    case File.mkdir_p(gate_dir) do
      :ok -> :ok
      {:error, reason} -> unavailable(gate_dir, :create_directory, reason)
    end
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
