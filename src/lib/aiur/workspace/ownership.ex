defmodule Aiur.Workspace.Ownership do
  @moduledoc """
  Process-scoped ownership for one issue workspace generation.

  A runner owns its registration from provisioning through provider shutdown.
  Registry cleanup on runner exit releases a crashed generation automatically.
  """

  @registry Aiur.Workspace.Ownership.Registry

  @type phase :: :provisioning | :active
  @type lease :: %{ticket: String.t(), generation: pos_integer(), owner_id: String.t(), phase: phase()}
  @type registry :: pid() | atom()

  @spec claim(String.t(), registry()) :: {:ok, lease()} | {:error, {:workspace_owned, {:ok, lease()} | :none}}
  def claim(ticket, registry \\ @registry) when is_binary(ticket) do
    generation = System.unique_integer([:positive, :monotonic])
    lease = %{ticket: ticket, generation: generation, owner_id: "workspace:#{generation}", phase: :provisioning}

    case Registry.register(registry, ticket, lease) do
      {:ok, _value} -> {:ok, lease}
      {:error, {:already_registered, _pid}} -> {:error, {:workspace_owned, current(ticket, registry)}}
    end
  end

  @spec activate(lease(), registry()) :: {:ok, lease()} | {:error, :workspace_ownership_lost}
  def activate(%{ticket: ticket, generation: generation}, registry \\ @registry) do
    case Registry.update_value(registry, ticket, &Map.put(&1, :phase, :active)) do
      {%{generation: ^generation, phase: :active} = lease, _previous_lease} ->
        {:ok, lease}

      :error ->
        {:error, :workspace_ownership_lost}
    end
  end

  @spec release(lease(), registry()) :: :ok
  def release(%{ticket: ticket}, registry \\ @registry) do
    :ok = Registry.unregister(registry, ticket)
  end

  @spec current(String.t(), registry()) :: {:ok, lease()} | :none
  def current(ticket, registry \\ @registry) when is_binary(ticket) do
    case Registry.lookup(registry, ticket) do
      [{_owner, lease}] -> {:ok, lease}
      [] -> :none
    end
  end

  @spec active?(String.t(), registry()) :: boolean()
  def active?(ticket, registry \\ @registry) when is_binary(ticket) do
    match?({:ok, %{phase: :active}}, current(ticket, registry))
  end

  @spec telemetry_metadata(lease()) :: map()
  def telemetry_metadata(%{owner_id: owner_id, generation: generation, phase: phase}) do
    %{workspace_owner: owner_id, workspace_generation: generation, workspace_phase: phase}
  end
end
