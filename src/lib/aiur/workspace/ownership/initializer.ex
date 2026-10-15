defmodule Aiur.Workspace.Ownership.Initializer do
  @moduledoc false

  alias Aiur.ProcessTree
  alias Aiur.Workspace.HostBoot
  alias Aiur.Workspace.Ownership.{AuditLog, Store}

  @spec lease(String.t(), pos_integer(), keyword()) :: map()
  def lease(ticket, generation, opts) do
    %{ticket: ticket, generation: generation, owner_id: "workspace:#{generation}", phase: Keyword.get(opts, :initial_phase, :provisioning), guardian: self()}
  end

  @spec receipt(keyword()) :: map()
  def receipt(opts) do
    Keyword.get(opts, :receipt, %{provider_expected?: false, provider: nil, provider_cleanup: :not_started, provider_scope: :unknown, provider_boot_id: nil})
  end

  @spec runtime_state(pid() | atom(), map(), reference() | nil, boolean(), map(), keyword()) :: map()
  def runtime_state(registry, lease, owner_ref, owner_dead?, receipt, opts) do
    %{
      owner_ref: owner_ref,
      owner_dead?: owner_dead?,
      registry: registry,
      store: Keyword.get(opts, :store, Store),
      lease: lease,
      provider_expected?: Map.get(receipt, :provider_expected?, false),
      provider: Map.get(receipt, :provider),
      provider_cleanup: Map.get(receipt, :provider_cleanup, :unresolved),
      provider_scope: Map.get(receipt, :provider_scope, :unknown),
      provider_boot_id: Map.get(receipt, :provider_boot_id),
      host_boot_id_fun: Keyword.get(opts, :host_boot_id_fun, &HostBoot.id/0),
      before_notify_fun: Keyword.get(opts, :before_notify_fun, fn _waiter -> :ok end),
      waiters: MapSet.new(),
      release_waiters: [],
      reap_fun: Keyword.get(opts, :reap_fun, &ProcessTree.reap_process_group/2),
      group_alive_fun: Keyword.get(opts, :group_alive_fun, &ProcessTree.process_group_alive?/1),
      root_reap_fun: Keyword.get(opts, :root_reap_fun, &ProcessTree.reap_process_tree/2),
      root_alive_fun: Keyword.get(opts, :root_alive_fun, &ProcessTree.process_alive?/1),
      process_reap_fun: Keyword.get(opts, :process_reap_fun, &ProcessTree.reap_process/2),
      process_alive_fun: Keyword.get(opts, :process_alive_fun, &ProcessTree.process_alive?/1),
      process_identity_fun: Keyword.get(opts, :process_identity_fun, &ProcessTree.process_identity/1),
      telemetry_fun: Keyword.get(opts, :telemetry_fun, fn _lease, _boundary, _outcome -> :ok end),
      audit_fun: Keyword.get(opts, :audit_fun, &AuditLog.write/1),
      host_lock: Map.get(receipt, :host_lock),
      reaping?: false,
      release_requested?: false
    }
  end
end
