defmodule Aiur.BuildGate do
  @moduledoc """
  Shared filesystem lease metadata for agent-launched Mix verification.

  The Bash hook owns acquisition and release so a running Mix command never
  depends on an Aiur BEAM staying alive. This module supplies its environment
  and reads the advisory records for Executor status.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.PathSafety

  @default_timeout_seconds 900
  @scan_output_budget_bytes 256 * 1024
  @recovery "repair the configured build-gate directory and retry, or fully disable build admission with " <>
              "agent.max_concurrent_builds: 0, agent.build_start_stagger_seconds: 0, and " <>
              "agent.min_free_memory_mb omitted"

  @type status :: %{
          required(:enabled?) => boolean(),
          required(:capacity) => non_neg_integer(),
          required(:active) => non_neg_integer(),
          required(:queued) => non_neg_integer(),
          required(:oldest_wait_seconds) => non_neg_integer() | nil,
          optional(:holders) => [holder()],
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
          required(:phase) => String.t() | nil,
          required(:command) => String.t() | nil,
          required(:started_at) => pos_integer() | nil,
          required(:held_for_seconds) => non_neg_integer() | nil
        }

  @spec shell_env(keyword()) :: [{String.t(), String.t()}]
  def shell_env(opts \\ []) do
    slots = Keyword.get_lazy(opts, :slots, &Config.max_concurrent_builds/0)
    stagger_seconds = Keyword.get_lazy(opts, :stagger_seconds, &Config.build_start_stagger_seconds/0)
    min_free_memory_mb = Keyword.get_lazy(opts, :min_free_memory_mb, &Config.min_free_memory_mb/0)

    if enabled?(slots: slots, stagger_seconds: stagger_seconds, min_free_memory_mb: min_free_memory_mb) do
      gate_dir = Keyword.get(opts, :gate_dir, gate_dir())
      lock_dir = Keyword.get(opts, :lock_dir, lock_dir(gate_dir))

      # AgentEnvironment builds this environment on the host for every backend.
      # Prepare immutable lock inodes there, before a sandbox receives only the
      # writable metadata root. A preparation failure remains fail-closed in the
      # shell hook, which reports the missing/unreadable lock path.
      _ = prepare_lock_namespace(lock_dir, slots)

      [
        {"BASH_ENV", Keyword.get(opts, :hook_path, hook_path())},
        {"AIUR_BUILD_GATE_DIR", gate_dir},
        {"AIUR_BUILD_GATE_LOCK_DIR", lock_dir},
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

  defp holder_path do
    :aiur
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("build_gate_holder.py")
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

      if linux_lock_strategy?(opts) do
        linux_status(gate_dir, Keyword.get(opts, :lock_dir, lock_dir(gate_dir)), capacity)
        |> with_oldest_wait()
      else
        pid_status(gate_dir, capacity)
        |> with_oldest_wait()
      end
    else
      %{enabled?: false, capacity: 0, active: 0, queued: 0, oldest_wait_seconds: 0, holders: []}
    end
  end

  defp pid_status(gate_dir, capacity) do
    {active, active_holders} = if(capacity > 0, do: active_count(gate_dir, capacity), else: {0, []})
    {queued, queue_holders} = queue_count(gate_dir)

    %{
      enabled?: true,
      capacity: capacity,
      active: active,
      queued: queued,
      holders: active_holders ++ queue_holders
    }
  end

  defp linux_status(gate_dir, lock_dir, capacity) do
    base = %{enabled?: true, capacity: capacity, active: 0, queued: 0, holders: []}

    cond do
      not File.exists?(gate_dir) ->
        base

      not File.dir?(gate_dir) ->
        degraded(base, [status_issue(:gate_directory_invalid, gate_dir)])

      true ->
        do_linux_status(base, gate_dir, lock_dir, capacity)
    end
  end

  defp do_linux_status(base, gate_dir, lock_dir, capacity) do
    case scan_locks(gate_dir, lock_dir, capacity) do
      {:ok, result} ->
        {active, queued, holders, issues} = reduce_scan_result(result)

        base
        |> Map.merge(%{active: active, queued: queued, holders: holders})
        |> degraded(legacy_issues(gate_dir) ++ issues)

      {:error, reason} ->
        degraded(base, [status_issue(:lock_probe_failed, gate_dir, reason)])
    end
  end

  defp scan_locks(gate_dir, lock_dir, capacity) do
    case System.find_executable("python3") do
      nil ->
        {:error, :safe_reader_unavailable}

      python ->
        with_scan_manifest(
          %{gate_dir: gate_dir, lock_dir: lock_dir, capacity: capacity},
          &run_lock_scan(python, &1)
        )
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_lock_scan(python, manifest_path) do
    case System.cmd(python, [holder_path(), "--scan-locks-manifest", manifest_path], stderr_to_stdout: true) do
      {output, 0} when byte_size(output) <= @scan_output_budget_bytes -> Jason.decode(String.trim(output))
      {output, 0} -> {:error, %{reason: :output_budget_exceeded, bytes: byte_size(output)}}
      {output, status} -> {:error, %{status: status, output: String.slice(String.trim(output), 0, 1_024)}}
    end
  end

  defp with_scan_manifest(request, fun) do
    path = Path.join(System.tmp_dir!(), "aiur-build-gate-scan-#{System.unique_integer([:positive, :monotonic])}.json")

    with {:ok, encoded} <- Jason.encode(request),
         {:ok, io_device} <- File.open(path, [:write, :exclusive]) do
      try do
        :ok = IO.binwrite(io_device, encoded)
        :ok = File.close(io_device)
        fun.(path)
      after
        File.close(io_device)
        File.rm(path)
      end
    end
  end

  defp reduce_scan_result(%{"active" => active, "queued" => queued, "details" => details, "issues" => scan_issues})
       when is_integer(active) and active >= 0 and is_integer(queued) and queued >= 0 and is_list(details) and
              is_list(scan_issues) do
    issues = Enum.flat_map(scan_issues, &scan_issue/1)

    {holders, issues} =
      Enum.reduce(details, {[], issues}, fn detail, {holders, issues} ->
        case scan_detail(detail) do
          {:ok, holder, metadata_issues} ->
            {prepend_holder(holders, holder), prepend_issues(issues, metadata_issues)}

          {:error, issue} ->
            {holders, [issue | issues]}
        end
      end)

    {active, queued, Enum.reverse(holders), Enum.reverse(issues)}
  end

  defp reduce_scan_result(_result),
    do: {0, 0, [], [status_issue(:lock_probe_failed, gate_dir(), :invalid_scan_result)]}

  defp scan_detail(%{
         "kind" => kind,
         "slot" => slot,
         "lock_path" => lock_path,
         "metadata_path" => metadata_path,
         "result" => %{"state" => "locked"} = result
       })
       when kind in ["slot", "queue", "phase"] and (is_nil(slot) or is_integer(slot)) and is_binary(lock_path) and
              is_binary(metadata_path) do
    candidate = %{kind: String.to_existing_atom(kind), slot: slot, lock_path: lock_path, metadata_path: metadata_path}
    {holder, issues} = inspected_metadata(result, candidate)
    {:ok, holder, issues}
  end

  defp scan_detail(detail), do: {:error, status_issue(:lock_probe_failed, gate_dir(), {:invalid_scan_detail, detail})}

  defp scan_issue(%{"reason" => "lock_probe_failed", "path" => path, "detail" => detail}) when is_binary(path),
    do: [status_issue(:lock_probe_failed, path, scan_error_detail(detail))]

  defp scan_issue(%{"reason" => "queue_unreadable", "path" => path, "detail" => detail}) when is_binary(path),
    do: [status_issue(:queue_unreadable, path, detail)]

  defp scan_issue(%{"reason" => "scan_budget_exceeded", "path" => path, "detail" => detail}) when is_binary(path),
    do: [status_issue(:scan_budget_exceeded, path, detail)]

  defp scan_issue(issue), do: [status_issue(:lock_probe_failed, gate_dir(), {:invalid_scan_issue, issue})]

  defp inspected_metadata(%{"metadata_error" => "not_regular"}, candidate),
    do: {nil, [status_issue(:metadata_not_regular, candidate.metadata_path)]}

  defp inspected_metadata(%{"metadata_error" => reason}, candidate),
    do: {nil, [status_issue(:metadata_unreadable, candidate.metadata_path, reason)]}

  defp inspected_metadata(%{"contents" => encoded}, %{kind: :phase, metadata_path: path}) do
    with {:ok, contents} <- Base.decode64(encoded),
         {:ok, _fields} <- parse_v2_record(contents) do
      {nil, []}
    else
      _error -> {nil, [status_issue(:metadata_unreadable, path, {:reader_status, 0})]}
    end
  end

  defp inspected_metadata(%{"contents" => encoded}, %{kind: kind, slot: slot, metadata_path: path}) do
    case Base.decode64(encoded) do
      {:ok, contents} -> inspect_metadata_contents(contents, path, kind, slot)
      :error -> {nil, [status_issue(:metadata_unreadable, path, :invalid_encoding)]}
    end
  end

  defp inspected_metadata(_result, _candidate), do: {nil, []}

  defp scan_error_detail(%{"reason" => "not_regular", "type" => "directory"}),
    do: %{reason: :not_regular, type: :directory}

  defp scan_error_detail(%{"reason" => "not_regular", "type" => "other"}),
    do: %{reason: :not_regular, type: :other}

  defp scan_error_detail(result), do: result

  defp inspect_metadata_contents("version=2\n" <> _rest = contents, path, kind, slot) do
    case parse_v2_record(contents) do
      {:ok, fields} -> {holder_from_fields(fields, kind, slot), []}
      :error -> {nil, [status_issue(:metadata_unreadable, path, {:reader_status, 0})]}
    end
  end

  defp inspect_metadata_contents(_contents, path, _kind, _slot),
    do: {nil, [status_issue(:metadata_unreadable, path, {:reader_status, 0})]}

  defp prepend_issues(issues, new_issues), do: Enum.reverse(new_issues, issues)
  defp prepend_holder(holders, nil), do: holders
  defp prepend_holder(holders, holder), do: [holder | holders]

  defp maybe_holder(holders, path, kind, slot) do
    case read_metadata(path) do
      {:ok, contents} ->
        case parse_v2_record(contents) do
          {:ok, fields} -> [holder_from_fields(fields, kind, slot) | holders]
          _ -> holders
        end

      _ ->
        holders
    end
  end

  # Safe, non-blocking read of a lease metadata record via the holder's regular
  # reader (rejects FIFOs/symlinks and never blocks on a hostile path). Returns
  # the raw record contents for version + holder parsing.
  defp read_metadata(path) do
    case System.find_executable("python3") do
      nil ->
        {:error, :safe_reader_unavailable}

      python ->
        case System.cmd(python, [holder_path(), "--read-regular", path], stderr_to_stdout: true) do
          {contents, 0} -> {:ok, contents}
          {_contents, 1} -> {:error, :missing}
          {_contents, 125} -> {:error, :not_regular}
          {_contents, status} -> {:error, {:reader_status, status}}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parse_v2_record(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, fields} when map_size(fields) > 0 -> {:ok, fields}
      _ -> :error
    end
  end

  defp holder_from_fields(fields, kind, slot) do
    now = System.os_time(:second)
    started_at = int_field(fields, "started_at")
    held_for_seconds = if is_integer(started_at) and started_at > 0 and now >= started_at, do: now - started_at, else: nil

    %{
      kind: kind,
      slot: slot,
      pid: int_field(fields, "pid"),
      pgid: int_field(fields, "pgid"),
      holder_pid: int_field(fields, "holder_pid"),
      command_pgid: int_field(fields, "command_pgid"),
      phase: Map.get(fields, "phase"),
      command: Map.get(fields, "command"),
      started_at: started_at,
      held_for_seconds: held_for_seconds
    }
  end

  defp int_field(fields, key) do
    case Map.get(fields, key) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end
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

  defp with_oldest_wait(%{degraded?: true} = status), do: Map.put(status, :oldest_wait_seconds, nil)
  defp with_oldest_wait(%{queued: 0} = status), do: Map.put(status, :oldest_wait_seconds, 0)

  defp with_oldest_wait(%{queued: queued, holders: holders} = status) do
    waits =
      holders
      |> Enum.filter(&(&1.kind == :queue))
      |> Enum.map(& &1.held_for_seconds)
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    oldest_wait = if length(waits) == queued, do: Enum.max(waits), else: nil
    Map.put(status, :oldest_wait_seconds, oldest_wait)
  end

  defp linux_lock_strategy?(opts) do
    case Keyword.get(opts, :strategy, :auto) do
      :linux_lock -> true
      :pid -> false
      :auto -> match?({:unix, :linux}, :os.type())
    end
  end

  defp active_count(gate_dir, capacity) do
    Enum.reduce(1..capacity, {0, []}, fn slot, {active, holders} ->
      slot_path = Path.join(gate_dir, "slot-#{slot}")
      owner_path = slot_owner_path(slot_path)

      cond do
        owner_record_alive?(owner_path) ->
          {active + 1, maybe_holder(holders, owner_path, :slot, slot)}

        stale_owner_record?(slot_path) ->
          # A lease whose holder has exited is reaped here so the slot becomes
          # available without operator action, mirroring the Linux status
          # reclaim of unlocked v2 metadata. Mirrors the Bash admission-time
          # `aiur_build_gate_reclaim_stale_slot`.
          File.rm_rf(slot_path)
          {active, holders}

        true ->
          {active, holders}
      end
    end)
    |> then(fn {active, holders} -> {active, Enum.reverse(holders)} end)
  end

  defp stale_owner_record?(slot_path) do
    owner_path = slot_owner_path(slot_path)
    File.exists?(owner_path) and not owner_record_alive?(owner_path)
  end

  defp slot_owner_path(slot_path) do
    if File.dir?(slot_path), do: Path.join(slot_path, "owner"), else: slot_path
  end

  defp queue_count(gate_dir) do
    queue_dir = Path.join(gate_dir, "queue")

    case File.ls(queue_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reduce({0, []}, &count_queue_entry_pid(&1, &2, queue_dir))
        |> then(fn {queued, holders} -> {queued, Enum.reverse(holders)} end)

      _ ->
        {0, []}
    end
  end

  defp count_queue_entry_pid(entry, {queued, holders}, queue_dir) do
    path = Path.join(queue_dir, entry)

    if owner_alive?(owner_pid(path)) do
      {queued + 1, maybe_holder(holders, path, :queue, nil)}
    else
      {queued, holders}
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
