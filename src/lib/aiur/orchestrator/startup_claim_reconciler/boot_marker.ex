defmodule Aiur.Orchestrator.StartupClaimReconciler.BootMarker do
  @moduledoc """
  Durable-in-VM claim that this daemon boot's startup pass has already run.

  Holds the `Aiur.Boot.run_id/0` of the boot that claimed the startup claim
  reconciliation pass. The marker lives in `:persistent_term`, so it survives
  an Orchestrator GenServer restart (its agent tasks survive too) but is
  cleared by a true daemon restart (fresh VM, fresh `run_id`). That is exactly
  the discriminator the reconciler needs: on an Orchestrator-only restart the
  marker still names the current boot and the pass must NOT re-run against an
  empty runtime registry, while a genuine daemon restart changes the boot id
  and the pass must run once to release every claim whose runtime died.

  Never fails (in-memory write); a failed write is impossible by construction.
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
