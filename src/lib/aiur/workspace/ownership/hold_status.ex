defmodule Aiur.Workspace.Ownership.HoldStatus do
  @moduledoc false

  alias Aiur.Workspace.HostBoot
  alias Aiur.Workspace.HostLock
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Store

  @type proof ::
          :same_boot | :owner_pid_dead | :boot_changed_release_pending | :boot_probe_unavailable | :remote | :not_recorded | :tracked_provider
  @type t :: %{generation: pos_integer(), proof: proof(), check_failed: atom() | nil}

  @spec for_ticket(String.t(), Ownership.registry(), GenServer.server(), (-> {:ok, String.t()} | :unknown)) :: t() | nil
  def for_ticket(ticket, registry \\ Aiur.Workspace.Ownership.Registry, store \\ Store, boot_id_fun \\ &HostBoot.id/0)
      when is_binary(ticket) do
    with {:ok, %{generation: generation, phase: :reaping}} <- Ownership.current(ticket, registry),
         {:ok, %{generation: ^generation} = receipt} <- Store.get(ticket, store) do
      {proof, check_failed} = proof(receipt, boot_id_fun)
      %{generation: generation, proof: proof, check_failed: check_failed}
    else
      _ -> nil
    end
  end

  defp proof(%{provider: provider}, _boot_id_fun) when is_map(provider) and map_size(provider) > 0,
    do: {:tracked_provider, :provider_still_tracked}

  defp proof(%{provider_expected?: true, provider_scope: :local, provider_boot_id: previous} = receipt, boot_id_fun)
       when is_binary(previous) and previous != "" do
    case boot_id_fun.() do
      {:ok, ^previous} -> dead_owner_proof(receipt)
      {:ok, current} when is_binary(current) and current != "" -> {:boot_changed_release_pending, nil}
      _ -> {:boot_probe_unavailable, :boot_probe_unavailable}
    end
  rescue
    _ -> {:boot_probe_unavailable, :boot_probe_unavailable}
  end

  defp proof(%{provider_expected?: true, provider_scope: :local} = receipt, _boot_id_fun), do: dead_owner_proof(receipt)

  defp proof(%{provider_expected?: true, provider_scope: :remote}, _boot_id_fun), do: {:remote, :remote_provider}
  defp proof(_receipt, _boot_id_fun), do: {:not_recorded, :provider_exit_not_recorded}

  defp dead_owner_proof(%{host_lock: host_lock}) do
    case HostLock.dead_owner_proof(get_in(host_lock || %{}, [:holder]), to_string(Node.self()), host_lock) do
      :owner_pid_dead -> {:owner_pid_dead, nil}
      {:keep, reason} -> {:same_boot, reason}
    end
  end

  defp dead_owner_proof(_receipt), do: {:same_boot, :host_lock_missing}
end
