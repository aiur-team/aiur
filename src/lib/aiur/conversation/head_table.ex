defmodule Aiur.Conversation.HeadTable do
  @moduledoc "Committed conversation snapshots; readers never invoke store recovery."
  use GenServer

  @table :aiur_conversation_heads

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Aiur.Project.via(__MODULE__))

  @impl true
  def init(opts) do
    Aiur.Project.adopt(opts)
    Aiur.Project.Table.new(@table, [:public, :set, read_concurrency: true])
    Aiur.Project.Table.new(:aiur_conversation_subjects, [:public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @spec put(String.t(), Path.t(), map()) :: :ok
  def put(id, dir, head) do
    :ets.insert(Aiur.Project.Table.ref(@table), {{dir, id}, head})
    :ok
  end

  @spec degraded?(String.t(), Path.t()) :: boolean()
  def degraded?(id, dir), do: :ets.member(Aiur.Project.Table.ref(@table), {:degraded, dir, id})

  @spec degraded(String.t(), Path.t() | nil, boolean()) :: :ok
  def degraded(id, dir, value) do
    if value, do: :ets.insert(Aiur.Project.Table.ref(@table), {{:degraded, dir, id}, true}), else: :ets.delete(Aiur.Project.Table.ref(@table), {:degraded, dir, id})
    :ok
  end

  @spec get(String.t(), Path.t()) :: {:ok, map()} | :missing
  def get(id, dir) do
    case :ets.lookup(Aiur.Project.Table.ref(@table), {dir, id}) do
      [{_, head}] -> {:ok, head}
      [] -> :missing
    end
  end
end
