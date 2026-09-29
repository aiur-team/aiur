defmodule Aiur.Workspace.Ownership.HoldStatus do
  @moduledoc false

  alias Aiur.Workspace.HostBoot
  alias Aiur.Workspace.Ownership
  alias Aiur.Workspace.Ownership.Store

  @type proof ::
          :same_boot | :boot_changed_release_pending | :boot_probe_unavailable | :remote | :not_recorded | :tracked_provider
  @type t :: %{generation: pos_integer(), proof: proof()}

  @spec for_ticket(String.t(), Ownership.registry(), GenServer.server(), (-> {:ok, String.t()} | :unknown)) :: t() | nil
  def for_ticket(ticket, registry \\ Aiur.Workspace.Ownership.Registry, store \\ Store, boot_id_fun \\ &HostBoot.id/0)
      when is_binary(ticket) do
    with {:ok, %{generation: generation, phase: :reaping}} <- Ownership.current(ticket, registry),
         {:ok, %{generation: ^generation} = receipt} <- Store.get(ticket, store) do
      %{generation: generation, proof: proof(receipt, boot_id_fun)}
    else
      _ -> nil
    end
  end

  defp proof(%{provider: provider}, _boot_id_fun) when is_map(provider) and map_size(provider) > 0,
    do: :tracked_provider

  defp proof(%{provider_expected?: true, provider_scope: :local, provider_boot_id: previous}, boot_id_fun)
       when is_binary(previous) and previous != "" do
    case boot_id_fun.() do
      {:ok, ^previous} -> :same_boot
      {:ok, current} when is_binary(current) and current != "" -> :boot_changed_release_pending
      _ -> :boot_probe_unavailable
    end
  rescue
    _ -> :boot_probe_unavailable
  end

  defp proof(%{provider_expected?: true, provider_scope: :remote}, _boot_id_fun), do: :remote
  defp proof(_receipt, _boot_id_fun), do: :not_recorded
end
