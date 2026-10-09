defmodule Aiur.Capabilities.Collector do
  @moduledoc false

  @known_ids ~w(identity api.http orchestration instance.status agents.run agents.message
    commands.read commands.answer commands.supervisor_api build_orders build_orders.progress
    build_queue build_queue.build_order_source conversations.read conversations.anchors
    executor.wakes executor.conversation executor.background_agents events.export listener_modes
    voice.stt voice.tts voice.conversation streamdeck webhook_ingress remote_control pairing push
    runtime.crypto tracker.github tracker.linear accounting.meters merge_policy)
  @unknown %{state: :unknown, reason: :unknown}

  @spec collect(keyword()) :: {map(), MapSet.t()}
  def collect(opts) do
    instance = Aiur.Identity.instance_section()
    context = %{run_shape: instance.run_shape, settings: settings()}
    providers = Keyword.get_lazy(opts, :providers, fn -> Application.get_env(:aiur, :capability_providers, []) end)
    supervisor = Keyword.get(opts, :task_supervisor, Aiur.TaskSupervisor)
    declarations = Enum.map(providers, &{&1, &1.capability_ids()})
    tasks = Enum.map(declarations, fn {provider, ids} -> {provider, ids, Task.Supervisor.async_nolink(supervisor, fn -> contribution(provider, context) end)} end)
    results = tasks |> Enum.map(&elem(&1, 2)) |> Task.yield_many(500) |> Map.new(fn {task, result} -> {task.ref, result} end)
    initial = {Map.new(@known_ids, &{&1, %{state: :unavailable, reason: :not_installed}}), %{}, MapSet.new(), MapSet.new()}
    {capabilities, sections, _claimed, warnings} = Enum.reduce(tasks, initial, &merge(&1, results, &2))

    machine =
      case Aiur.Identity.machine() do
        {:ok, machine} -> machine
        {:degraded, _reason} -> nil
      end

    {%{machine: machine, instance: instance, repository: sections[:repository], executor: sections[:executor], capabilities: capabilities}, warnings}
  rescue
    error -> failed_collection(Exception.format_banner(:error, error))
  catch
    kind, reason -> failed_collection(Exception.format_banner(kind, reason))
  end

  defp failed_collection(detail) do
    entry = %{state: :unknown, reason: :collection_failed, detail: detail}
    report = %{machine: nil, instance: nil, repository: nil, executor: nil, capabilities: Map.new(@known_ids, &{&1, entry})}
    {report, MapSet.new([{:collection_failed, detail}])}
  end

  defp settings do
    case Aiur.Config.settings() do
      {:ok, settings} -> settings
      {:error, _reason} -> :unavailable
    end
  end

  defp contribution(provider, context) do
    capabilities = provider.capabilities(context)
    sections = if function_exported?(provider, :sections, 1), do: provider.sections(context), else: %{}
    {Map.new(capabilities), Map.take(sections, [:repository, :executor])}
  rescue
    _error -> :failed
  catch
    _kind, _reason -> :failed
  end

  defp merge({provider, ids, task}, results, {caps, sections, claimed, warnings}) do
    {entries, contributed, warnings} = result(provider, ids, task, results[task.ref], warnings)
    duplicates = Enum.filter(ids, &MapSet.member?(claimed, &1))
    caps = Map.merge(caps, Map.take(entries, ids))
    caps = Enum.reduce(duplicates, caps, &Map.put(&2, &1, @unknown))
    warnings = Enum.reduce(duplicates, warnings, &MapSet.put(&2, {:duplicate, &1}))
    {caps, Map.merge(sections, contributed), Enum.reduce(ids, claimed, &MapSet.put(&2, &1)), warnings}
  end

  defp result(provider, ids, _task, {:ok, {entries, sections}}, warnings) do
    undeclared = Map.keys(entries) -- ids
    warnings = if undeclared == [], do: warnings, else: MapSet.put(warnings, {:undeclared, provider, Enum.sort(undeclared)})
    {Map.merge(Map.new(ids, &{&1, @unknown}), entries), sections, warnings}
  end

  defp result(provider, ids, task, failure, warnings) do
    if is_nil(failure), do: Task.shutdown(task, :brutal_kill)
    {Map.new(ids, &{&1, @unknown}), %{}, MapSet.put(warnings, {:failed, provider})}
  end
end
