defmodule Aiur.ProcessIdentity do
  @moduledoc false

  @spec alive?(nil | integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  rescue
    # A probe failure is not evidence that a process is gone. Callers use this
    # result to decide whether destructive cleanup or stale-lock recovery is safe.
    _ -> true
  end

  def alive?(_os_pid), do: false

  @spec resolve(nil | integer()) :: {:ok, term()} | :gone | :unknown
  def resolve(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> procfs_process_identity(stat)
      {:error, _reason} -> ps_process_identity(os_pid)
    end
  rescue
    _ -> :unknown
  end

  def resolve(_os_pid), do: :gone

  defp procfs_process_identity(stat) do
    case List.last(:binary.matches(stat, ")")) do
      {closing_paren, _length} ->
        stat
        |> binary_part(closing_paren + 1, byte_size(stat) - closing_paren - 1)
        |> String.split()
        |> then(fn fields -> {Enum.at(fields, 3), Enum.at(fields, 19)} end)
        |> procfs_fields_identity()

      nil ->
        :unknown
    end
  end

  defp procfs_fields_identity({session, start_time})
       when is_binary(session) and is_binary(start_time) and byte_size(session) > 0 and
              byte_size(start_time) > 0,
       do: {:ok, {:procfs_birth_and_session, start_time, session}}

  defp procfs_fields_identity(_fields), do: :unknown

  defp ps_process_identity(os_pid) do
    case System.find_executable("ps") do
      nil ->
        :unknown

      ps ->
        ps
        |> System.cmd(["-o", "lstart=", "-o", "sess=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true)
        |> ps_process_result()
    end
  rescue
    _ -> :unknown
  end

  defp ps_process_result({output, 0}) do
    case String.trim(output) do
      "" -> :gone
      identity -> {:ok, {:ps_birth_and_session, identity}}
    end
  end

  defp ps_process_result(_result), do: :gone
end
