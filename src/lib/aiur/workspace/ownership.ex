defmodule Aiur.Workspace.Ownership do
  @moduledoc """
  Public lease API for one workspace generation.

  The guardian owns registry lifetime and containment; this module deliberately
  stays thin so callers cannot bypass generation checks or release ordering.
  """

  alias Aiur.Workspace.Ownership.{Guardian, Waiter}

  @registry Aiur.Workspace.Ownership.Registry
  @guardian_call_timeout 5_000

  @type phase :: :provisioning | :active | :reaping | :released
  @type lease :: %{
          ticket: String.t(),
          generation: pos_integer(),
          owner_id: String.t(),
          phase: phase(),
          guardian: pid()
        }
  @type registry :: pid() | atom()

  @spec claim(String.t(), registry()) :: {:ok, lease()} | {:error, {:workspace_owned, {:ok, lease()} | :none}}
  def claim(ticket, registry \\ @registry), do: claim(ticket, registry, [])

  @doc false
  @spec claim(String.t(), registry(), keyword()) ::
          {:ok, lease()} | {:error, {:workspace_owned, {:ok, lease()} | :none}}
  def claim(ticket, registry, opts) when is_binary(ticket) and is_list(opts) do
    guardian = Guardian.start(self(), ticket, System.unique_integer([:positive, :monotonic]), registry, opts)

    receive do
      {:workspace_guardian_claimed, ^guardian, result} -> result
    after
      @guardian_call_timeout ->
        Process.exit(guardian, :kill)
        {:error, {:workspace_owned, current(ticket, registry)}}
    end
  end

  @spec activate(lease(), registry()) :: {:ok, lease()} | {:error, :workspace_ownership_lost}
  def activate(lease, registry \\ @registry)
  def activate(%{guardian: guardian, generation: generation}, _registry) when is_pid(guardian), do: call(guardian, {:activate, generation})
  def activate(_lease, _registry), do: {:error, :workspace_ownership_lost}

  @doc false
  @spec expect_provider(lease() | nil) :: :ok | {:error, :workspace_ownership_lost}
  def expect_provider(%{guardian: guardian, generation: generation}) when is_pid(guardian), do: call(guardian, {:expect_provider, generation})
  def expect_provider(nil), do: {:error, :workspace_ownership_lost}
  def expect_provider(_lease), do: {:error, :workspace_ownership_lost}

  @doc false
  @spec cancel_provider_expectation(lease() | nil) :: :ok | {:error, :workspace_ownership_lost}
  def cancel_provider_expectation(%{guardian: guardian, generation: generation}) when is_pid(guardian),
    do: call(guardian, {:cancel_provider_expectation, generation})

  def cancel_provider_expectation(_lease), do: {:error, :workspace_ownership_lost}

  @doc false
  @spec track_provider(lease() | nil, map()) :: :ok | {:error, :workspace_ownership_lost}
  def track_provider(%{guardian: guardian, generation: generation}, provider) when is_pid(guardian) and is_map(provider),
    do: call(guardian, {:track_provider, generation, provider})

  def track_provider(nil, _provider), do: {:error, :workspace_ownership_lost}
  def track_provider(_lease, _provider), do: {:error, :workspace_ownership_lost}

  @spec track_process_group(lease() | nil, integer()) :: :ok | {:error, :workspace_ownership_lost}
  def track_process_group(lease, process_group_id) when is_integer(process_group_id) and process_group_id > 0,
    do: track_provider(lease, %{process_group_id: process_group_id})

  def track_process_group(nil, _process_group_id), do: {:error, :workspace_ownership_lost}
  def track_process_group(_lease, _process_group_id), do: {:error, :workspace_ownership_lost}

  @spec release(lease(), registry()) :: :ok
  def release(lease, registry \\ @registry)
  def release(%{guardian: guardian, generation: generation}, _registry) when is_pid(guardian), do: call(guardian, {:release, generation})
  def release(_lease, _registry), do: :ok

  @doc false
  @spec release_and_wait(lease()) :: {:ok, lease()} | {:error, :workspace_ownership_lost}
  def release_and_wait(%{guardian: guardian, generation: generation}) when is_pid(guardian),
    do: call(guardian, {:release_and_wait, generation})

  def release_and_wait(_lease), do: {:error, :workspace_ownership_lost}

  @doc false
  @spec wait_for_release(String.t(), pid(), registry()) ::
          {:waiting, pid(), pos_integer()} | :available
  def wait_for_release(ticket, recipient, registry \\ @registry) when is_binary(ticket) and is_pid(recipient),
    do: Waiter.wait(ticket, recipient, registry)

  @spec current(String.t(), registry()) :: {:ok, lease()} | :none
  def current(ticket, registry \\ @registry) when is_binary(ticket) do
    case Registry.lookup(registry, ticket) do
      [{_guardian, lease}] -> {:ok, lease}
      [] -> :none
    end
  end

  @spec active?(String.t(), registry()) :: boolean()
  def active?(ticket, registry \\ @registry), do: match?({:ok, %{phase: :active}}, current(ticket, registry))

  @doc false
  @spec protected?(String.t(), registry()) :: boolean()
  def protected?(ticket, registry \\ @registry),
    do: match?({:ok, %{phase: phase}} when phase in [:active, :reaping], current(ticket, registry))

  @spec telemetry_metadata(lease()) :: map()
  def telemetry_metadata(%{owner_id: owner_id, generation: generation, phase: phase}),
    do: %{workspace_owner: owner_id, workspace_generation: generation, workspace_phase: phase}

  defp call(guardian, message) do
    ref = make_ref()
    send(guardian, {:workspace_guardian_call, self(), ref, message})

    receive do
      {:workspace_guardian_reply, ^ref, result} -> result
    after
      @guardian_call_timeout -> timeout_result(message)
    end
  end

  defp timeout_result({operation, _generation}) when operation in [:activate, :expect_provider, :cancel_provider_expectation, :track_provider],
    do: {:error, :workspace_ownership_lost}

  defp timeout_result({:release_and_wait, _generation}), do: {:error, :workspace_ownership_lost}
  defp timeout_result(_message), do: :ok
end
