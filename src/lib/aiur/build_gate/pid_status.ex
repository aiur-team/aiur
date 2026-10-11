defmodule Aiur.BuildGate.PidStatus do
  @moduledoc false

  alias Aiur.BuildGate.Status

  @spec read(Path.t(), non_neg_integer()) :: map()
  def read(gate_dir, capacity) do
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

  defp active_count(gate_dir, capacity) do
    Enum.reduce(1..capacity, {0, []}, fn slot, {active, holders} ->
      slot_path = Path.join(gate_dir, "slot-#{slot}")
      owner_path = slot_owner_path(slot_path)

      cond do
        owner_record_alive?(owner_path) ->
          {active + 1, Status.maybe_holder(holders, owner_path, :slot, slot)}

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
      {queued + 1, Status.maybe_holder(holders, path, :queue, nil)}
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
    owner_alive?(owner_pid(path)) or Status.process_group_alive?(owner_pgid(path))
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
end
