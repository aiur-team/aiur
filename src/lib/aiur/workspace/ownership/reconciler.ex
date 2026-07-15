defmodule Aiur.Workspace.Ownership.Reconciler do
  @moduledoc false

  use GenServer

  alias Aiur.Workspace.Ownership.{Guardian, Store}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, Store)
    registry = Keyword.get(opts, :registry, Aiur.Workspace.Ownership.Registry)
    guardian_opts = Keyword.get(opts, :guardian_opts, []) |> Keyword.put(:store, store)

    with {:ok, receipts} <- Store.all(store),
         {:ok, guardians} <- restore_all(receipts, registry, guardian_opts) do
      {:ok, %{guardians: guardians}}
    else
      {:error, reason} -> {:stop, {:workspace_ownership_reconciliation_failed, reason}}
    end
  end

  defp restore_all(receipts, registry, guardian_opts) do
    Enum.reduce_while(receipts, {:ok, []}, fn {_ticket, receipt}, {:ok, guardians} ->
      case Guardian.restore(receipt, registry, guardian_opts) do
        {:ok, lease} -> {:cont, {:ok, [lease.guardian | guardians]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
