defmodule Aiur.Orchestrator.StartupClaimReconciler.BootMarker do
  @moduledoc """
  Records the boot that began claim reconciliation, surviving Orchestrator restarts.

  The marker does not disable periodic recovery. Current runtime and workspace
  ownership evidence protect surviving sessions before any release.
  """

  @key {__MODULE__, :claimed_boot_id}

  @doc "The boot id whose startup pass this daemon boot has claimed, or nil."
  @spec claimed_boot_id() :: String.t() | nil
  def claimed_boot_id do
    :persistent_term.get(@key, nil)
  end

  @doc "Claims the current daemon boot for the startup pass."
  @spec claim(String.t()) :: :ok
  def claim(boot_id) when is_binary(boot_id) do
    :persistent_term.put(@key, boot_id)
    :ok
  end

  @doc "Clears the claim. Test helper and manual re-arm for an operator."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end
end
