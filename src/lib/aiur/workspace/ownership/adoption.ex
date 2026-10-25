defmodule Aiur.Workspace.Ownership.Adoption do
  @moduledoc "Acquires an active lease for an existing local workspace without provisioning it."

  alias Aiur.Workspace.{HostLock, Ownership}
  alias Aiur.Workspace.Ownership.{Guardian, Store}

  @spec adopt(String.t(), Path.t(), keyword()) :: {:ok, Ownership.lease()} | {:error, term()}
  def adopt(identifier, workspace, opts \\ []) do
    :global.trans({{__MODULE__, workspace}, self()}, fn -> acquire(identifier, workspace, opts) end)
  end

  defp acquire(identifier, workspace, opts) do
    registry = Keyword.get(opts, :registry, Ownership.Registry)
    store = Keyword.get(opts, :store, Store)

    with true <- File.dir?(workspace),
         :none <- Ownership.current(identifier, registry),
         {:ok, receipt} <- Store.get(identifier, store),
         {:ok, lock} <- acquire_lock(workspace, identifier, receipt, opts) do
      start(identifier, registry, lock, receipt, Keyword.put(opts, :store, store))
    else
      false -> {:error, :workspace_missing}
      {:ok, lease} -> {:error, {:workspace_owned, {:ok, lease}}}
      error -> error
    end
  end

  defp acquire_lock(workspace, identifier, receipt, opts) do
    previous_owner = get_in(receipt || %{}, [:host_lock, :holder, :owner_id])
    daemon_pid = :os.getpid() |> List.to_string() |> String.to_integer()

    case HostLock.holder(workspace) do
      {:ok, %{ticket: ^identifier, os_pid: ^daemon_pid, owner_id: ^previous_owner} = holder} ->
        {:ok, %{path: HostLock.lock_path(workspace), workspace: workspace, holder: holder}}

      _ ->
        HostLock.acquire(workspace, identifier, Keyword.get(opts, :host_lock_opts, []))
    end
  end

  defp start(identifier, registry, lock, receipt, opts) do
    provider = Keyword.get(opts, :provider, (receipt || %{})[:provider])
    receipt = Map.merge(receipt || %{}, %{host_lock: lock, provider: provider, provider_cleanup: :unresolved})
    holder = %{issue_id: Keyword.get(opts, :issue_id), update_recipient: Keyword.get(opts, :orchestrator), update_recipient_name: Keyword.get(opts, :orchestrator_name)}
    opts = Keyword.merge(opts, initial_phase: :active, receipt: receipt, holder: holder)
    guardian = Guardian.start(self(), identifier, System.unique_integer([:positive, :monotonic]), registry, opts)

    receive do
      {:workspace_guardian_claimed, ^guardian, {:ok, lease}} -> {:ok, lease}
      {:workspace_guardian_claimed, ^guardian, error} -> cleanup(lock, error)
    after
      5_000 ->
        Process.exit(guardian, :kill)
        cleanup(lock, {:error, :workspace_reconciliation_timeout})
    end
  end

  defp cleanup(lock, result) do
    HostLock.release(lock)
    result
  end
end
