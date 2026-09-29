defmodule Aiur.Workspace.HostBoot do
  @moduledoc false

  @boot_id_path "/proc/sys/kernel/random/boot_id"
  @boot_id_pattern ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  # A changed Linux kernel boot ID proves that no local OS process from the
  # previous boot can still own a workspace. An unavailable probe is never
  # evidence of exit, including on hosts without procfs.
  @spec id() :: {:ok, String.t()} | :unknown
  def id do
    case File.read(@boot_id_path) do
      {:ok, value} ->
        parse(value)

      {:error, _reason} ->
        :unknown
    end
  end

  @doc false
  @spec parse(String.t()) :: {:ok, String.t()} | :unknown
  def parse(value) when is_binary(value) do
    boot_id = String.trim(value)
    if Regex.match?(@boot_id_pattern, boot_id), do: {:ok, boot_id}, else: :unknown
  end
end
