defmodule Aiur.Workspace.Ownership.Guardian.Provider do
  @moduledoc false

  @spec valid_provider?(map()) :: boolean()
  def valid_provider?(%{remote: true}), do: true
  def valid_provider?(%{process_group_id: process_group_id}) when is_integer(process_group_id) and process_group_id > 0, do: true
  def valid_provider?(%{root_pid: root_pid}) when is_integer(root_pid) and root_pid > 0, do: true

  def valid_provider?(%{descendant_pids: pids}) when is_list(pids),
    do: Enum.any?(pids, &(is_integer(&1) and &1 > 0))

  # An in-process session (an OpenAI-compatible HTTP agent) owns no OS process:
  # it is a child of the runner and dies with it, so there is nothing to reap on
  # owner death. Accept it so the workspace lease stays valid for its lifetime.
  def valid_provider?(%{in_process: true}), do: true

  def valid_provider?(_provider), do: false

  # A provider can be reported more than once while its session is starting.
  # Each process-tree result is only a point-in-time observation, so narrowing
  # a later observation must not make an already observed descendant disposable.
  # The `in_process` marker is session-level, not a point-in-time observation:
  # once set it stays set across merges.
  @spec merge_provider(map(), map()) :: map()
  def merge_provider(previous, incoming) do
    merged =
      Map.merge(previous, Map.take(incoming, [:process_group_id, :root_pid, :remote, :descendant_pids]))

    merged =
      if Map.get(previous, :in_process) == true or Map.get(incoming, :in_process) == true do
        Map.put(merged, :in_process, true)
      else
        merged
      end

    if Map.has_key?(previous, :descendant_pids) or Map.has_key?(incoming, :descendant_pids) do
      descendants =
        [previous, incoming]
        |> Enum.flat_map(&observed_descendant_pids/1)
        |> Enum.uniq()

      Map.put(merged, :descendant_pids, descendants)
    else
      merged
    end
  end

  defp observed_descendant_pids(provider) do
    case Map.get(provider, :descendant_pids) do
      pids when is_list(pids) -> Enum.filter(pids, &(is_integer(&1) and &1 > 0))
      _ -> []
    end
  end

  # An `in_process` provider is only releasable without reaping while it has no
  # OS identity at all. A later merge can pair the marker with a process group,
  # root, remote host, or descendants; those must be reaped first.
  @spec in_process_only?(map()) :: boolean()
  def in_process_only?(provider) do
    Map.get(provider, :in_process) == true and
      Map.get(provider, :process_group_id) == nil and
      Map.get(provider, :root_pid) == nil and
      Map.get(provider, :remote) == nil and
      not has_positive_descendants?(provider)
  end

  defp has_positive_descendants?(provider) do
    provider
    |> Map.get(:descendant_pids, [])
    |> Enum.any?(&(is_integer(&1) and &1 > 0))
  end

  @spec capture_provider_identities(map(), function()) :: map()
  def capture_provider_identities(provider, process_identity_fun) do
    Enum.reduce(provider_identifiers(provider), provider, fn {kind, identifier}, provider ->
      identities = Map.get(provider, :process_identities, %{})
      key = {kind, identifier}

      if Map.has_key?(identities, key) do
        provider
      else
        Map.put(provider, :process_identities, Map.put(identities, key, capture_process_identity(process_identity_fun, identifier)))
      end
    end)
  end

  defp provider_identifiers(provider) do
    groups = identifier_entries(:group, Map.get(provider, :process_group_id))
    roots = identifier_entries(:root, Map.get(provider, :root_pid))

    processes =
      provider
      |> Map.get(:descendant_pids, [])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.map(&{:process, &1})

    groups ++ roots ++ processes
  end

  defp identifier_entries(kind, identifier) when is_integer(identifier) and identifier > 0, do: [{kind, identifier}]
  defp identifier_entries(_kind, _identifier), do: []

  defp capture_process_identity(process_identity_fun, identifier) do
    case process_identity_fun.(identifier) do
      {:ok, identity} -> {:known, identity}
      :gone -> :gone
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  @spec provider_identity_state(map(), atom(), pos_integer(), function()) :: atom()
  def provider_identity_state(state, kind, identifier, alive_fun) do
    expected_identity = provider_identity(state, kind, identifier)

    compare_provider_identity(expected_identity, state.process_identity_fun, alive_fun, identifier)
  end

  defp provider_identity(%{provider: provider}, kind, identifier),
    do: provider_identity(provider, kind, identifier)

  defp provider_identity(provider, kind, identifier) when is_map(provider),
    do: provider |> Map.get(:process_identities, %{}) |> Map.get({kind, identifier})

  defp provider_identity(_provider, _kind, _identifier), do: :unknown

  @spec reaping_identity(map(), atom(), term()) :: term()
  def reaping_identity(state, :processes, identifiers) when is_list(identifiers),
    do: Map.new(identifiers, &{&1, provider_identity(state, :process, &1)})

  def reaping_identity(state, kind, identifier), do: provider_identity(state, kind, identifier)

  defp compare_provider_identity({:known, expected}, process_identity_fun, alive_fun, identifier) do
    case capture_process_identity(process_identity_fun, identifier) do
      {:known, ^expected} -> liveness_state(alive_fun, identifier, :live)
      {:known, _other_identity} -> :reused
      :gone -> liveness_state(alive_fun, identifier, :unknown)
      :unknown -> :unknown
    end
  end

  defp compare_provider_identity(:gone, _process_identity_fun, alive_fun, identifier),
    do: liveness_state(alive_fun, identifier, :unknown)

  defp compare_provider_identity(_expected, _process_identity_fun, _alive_fun, _identifier), do: :unknown

  defp liveness_state(alive_fun, identifier, alive_state) do
    if safely_alive?(alive_fun, identifier), do: alive_state, else: :gone
  end

  @spec safely_alive?(function(), pos_integer()) :: boolean()
  def safely_alive?(alive_fun, identifier) do
    alive_fun.(identifier)
  rescue
    _ -> true
  end

  @spec live_provider_processes(map()) :: map()
  def live_provider_processes(%{provider: provider} = state) do
    provider
    |> provider_process_identifiers()
    |> Enum.reduce(%{live: [], unverified?: false}, fn {kind, identifier}, result ->
      case provider_identity_state(state, kind, identifier, state.process_alive_fun) do
        :live -> %{result | live: [identifier | result.live]}
        :unknown -> %{result | unverified?: true}
        _ -> result
      end
    end)
    |> Map.update!(:live, &Enum.uniq/1)
  end

  defp provider_process_identifiers(provider) do
    roots = identifier_entries(:root, Map.get(provider, :root_pid))

    processes =
      provider
      |> Map.get(:descendant_pids, [])
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.map(&{:process, &1})

    Enum.uniq_by(roots ++ processes, fn {_kind, identifier} -> identifier end)
  end
end
