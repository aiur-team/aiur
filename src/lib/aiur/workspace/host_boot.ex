defmodule Aiur.Workspace.HostBoot do
  @moduledoc false

  @boot_id_path "/proc/sys/kernel/random/boot_id"

  # A changed Linux kernel boot ID proves that no local OS process from the
  # previous boot can still own a workspace. An unavailable probe is never
  # evidence of exit, including on hosts without procfs.
  @spec id() :: {:ok, String.t()} | :unknown
  def id do
    case File.read(@boot_id_path) do
      {:ok, value} ->
        case String.trim(value) do
          <<_::binary-size(36)>> = boot_id -> {:ok, boot_id}
          _ -> :unknown
        end

      {:error, _reason} ->
        :unknown
    end
  end
end
