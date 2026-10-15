defmodule Aiur.Handoff.Protection do
  @moduledoc "Shutdown protection for runtimes committed to a durable handoff."

  @key {__MODULE__, :prepared}

  @spec prepared() :: map() | nil
  def prepared, do: :persistent_term.get(@key, nil)

  @spec store(pid(), map(), MapSet.t()) :: :ok
  def store(owner, result, tickets) do
    :persistent_term.put(@key, %{owner: owner, result: result, tickets: tickets})
  end

  @spec active?() :: boolean()
  def active?, do: not is_nil(prepared())

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  @spec protected?(term()) :: boolean()
  def protected?(identifier) do
    case prepared() do
      %{tickets: tickets} -> MapSet.member?(tickets, to_string(identifier))
      nil -> false
    end
  end
end
