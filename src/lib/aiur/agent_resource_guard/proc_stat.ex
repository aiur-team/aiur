defmodule Aiur.AgentResourceGuard.ProcStat do
  @moduledoc false

  @spec read(Path.t(), pos_integer()) :: map() | nil
  def read(proc_root, pid) do
    with {:ok, stat} <- :prim_file.read_file(Path.join([proc_root, Integer.to_string(pid), "stat"])),
         {offset, 2} <- List.last(:binary.matches(stat, ") ")),
         [_, comm] <- :binary.split(binary_part(stat, 0, offset), " ("),
         [_state, ppid, pgid, sid | _] <- :binary.split(binary_part(stat, offset + 2, byte_size(stat) - offset - 2), " ", [:global, :trim_all]),
         {ppid, ""} <- Integer.parse(ppid),
         {pgid, ""} <- Integer.parse(pgid),
         {sid, ""} <- Integer.parse(sid) do
      %{comm: comm, ppid: ppid, pgid: pgid, sid: sid}
    else
      _ -> nil
    end
  end
end
