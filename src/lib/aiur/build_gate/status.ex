defmodule Aiur.BuildGate.Status do
  @moduledoc false

  alias Aiur.BuildGate

  @scan_output_budget_bytes 256 * 1024
  @recovery "repair the configured build-gate directory and retry, or fully disable build admission with " <>
              "agent.max_concurrent_builds: 0, agent.build_start_stagger_seconds: 0, and " <>
              "agent.min_free_memory_mb omitted"

  @spec recovery() :: String.t()
  def recovery, do: @recovery

  defp holder_path do
    :aiur
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("build_gate_holder.py")
  end

  @spec linux(Path.t(), Path.t(), non_neg_integer()) :: map()
  def linux(gate_dir, lock_dir, capacity) do
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
        |> Map.merge(%{
          active: active,
          queued: queued,
          holders: holders,
          timeouts: linux_hold_timeouts(gate_dir)
        })
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
    path = Path.join(System.tmp_dir!(), "aiur-build-gate-scan-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}.json")

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
    do: {0, 0, [], [status_issue(:lock_probe_failed, BuildGate.gate_dir(), :invalid_scan_result)]}

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

  defp scan_detail(detail), do: {:error, status_issue(:lock_probe_failed, BuildGate.gate_dir(), {:invalid_scan_detail, detail})}

  defp scan_issue(%{"reason" => "lock_probe_failed", "path" => path, "detail" => detail}) when is_binary(path),
    do: [status_issue(:lock_probe_failed, path, scan_error_detail(detail))]

  defp scan_issue(%{"reason" => "queue_unreadable", "path" => path, "detail" => detail}) when is_binary(path),
    do: [status_issue(:queue_unreadable, path, detail)]

  defp scan_issue(%{"reason" => "scan_budget_exceeded", "path" => path, "detail" => detail}) when is_binary(path),
    do: [status_issue(:scan_budget_exceeded, path, detail)]

  defp scan_issue(issue), do: [status_issue(:lock_probe_failed, BuildGate.gate_dir(), {:invalid_scan_issue, issue})]

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

  @spec maybe_holder([BuildGate.holder()], Path.t(), :slot | :queue, pos_integer() | nil) :: [BuildGate.holder()]
  def maybe_holder(holders, path, kind, slot) do
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
    command_pgid = int_field(fields, "command_pgid")

    %{
      kind: kind,
      slot: slot,
      pid: int_field(fields, "pid"),
      pgid: int_field(fields, "pgid"),
      holder_pid: int_field(fields, "holder_pid"),
      command_pgid: command_pgid,
      # A slot whose command process group is gone is "held, command gone" —
      # a leaked holder waiting on reparented daemons, not a running build
      # (#2349). nil means the record cannot tell (no command_pgid).
      command_alive?: command_alive?(command_pgid),
      phase: Map.get(fields, "phase"),
      command: Map.get(fields, "command"),
      started_at: started_at,
      held_for_seconds: held_for_seconds
    }
  end

  defp command_alive?(command_pgid) when is_integer(command_pgid) and command_pgid > 0,
    do: process_group_alive?(command_pgid)

  defp command_alive?(_command_pgid), do: nil

  # Durable `slot-N.hold-timeout` markers the detached lease holder writes when
  # it self-releases at the absolute max-hold cap (#2349). Reported on the
  # status surface and consumed by BuildGateHoldMonitor to raise a
  # needs-attention alert naming the command, so the alert survives the race
  # between the holder releasing and the daemon's next poll.
  defp linux_hold_timeouts(gate_dir) do
    case File.ls(gate_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".hold-timeout"))
        |> Enum.flat_map(&parse_timeout_marker(Path.join(gate_dir, &1)))

      _ ->
        []
    end
  end

  defp parse_timeout_marker(path) do
    case read_metadata(path) do
      {:ok, contents} ->
        case parse_v2_record(contents) do
          {:ok, fields} -> [timeout_from_fields(fields, path)]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp timeout_from_fields(fields, path) do
    slot =
      case Path.basename(path) do
        "slot-" <> rest ->
          case Integer.parse(rest) do
            {slot, ".hold-timeout"} -> slot
            _ -> nil
          end

        _ ->
          nil
      end

    %{
      slot: slot,
      command: Map.get(fields, "command"),
      held_for_seconds: int_field(fields, "held_for_seconds"),
      reason: Map.get(fields, "reason"),
      path: path
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

  @spec with_oldest_wait(map()) :: map()
  def with_oldest_wait(%{degraded?: true} = status), do: Map.put(status, :oldest_wait_seconds, nil)
  def with_oldest_wait(%{queued: 0} = status), do: Map.put(status, :oldest_wait_seconds, 0)

  def with_oldest_wait(%{queued: queued, holders: holders} = status) do
    waits =
      holders
      |> Enum.filter(&(&1.kind == :queue))
      |> Enum.map(& &1.held_for_seconds)
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    oldest_wait = if length(waits) == queued, do: Enum.max(waits), else: nil
    Map.put(status, :oldest_wait_seconds, oldest_wait)
  end

  @spec process_group_alive?(term()) :: boolean()
  def process_group_alive?(pgid) when is_integer(pgid) and pgid > 0 do
    case System.find_executable("sh") do
      nil -> false
      shell -> match?({_output, 0}, System.cmd(shell, ["-c", "kill -0 -#{pgid}"], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  def process_group_alive?(_pgid), do: false
end
