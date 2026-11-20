defmodule Aiur.Capabilities.Collector do
  @moduledoc false
  require Logger

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
    timeout = Keyword.get(opts, :timeout_ms, 500)
    results = await(tasks, timeout, opts, supervisor, context)
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
    entry = %{state: :unknown, reason: :unknown, detail: detail}
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
    error -> {:failed, Exception.format_banner(:error, error)}
  catch
    kind, reason -> {:failed, Exception.format_banner(kind, reason)}
  end

  defp await(tasks, timeout, opts, supervisor, context) do
    started = System.monotonic_time(:millisecond)
    first = tasks |> Enum.map(&elem(&1, 2)) |> Task.yield_many(timeout) |> Map.new(fn {task, result} -> {task.ref, result} end)

    timed_out = Enum.filter(tasks, fn {_provider, _ids, task} -> is_nil(first[task.ref]) end)
    retried = if boot_retry?(opts), do: retry(timed_out, timeout, supervisor, context), else: %{}

    Map.new(tasks, fn {_provider, _ids, task} ->
      elapsed = System.monotonic_time(:millisecond) - started
      value = Map.get(first, task.ref)
      value = if is_nil(value), do: Map.get(retried, task.ref), else: value
      {task.ref, if(is_nil(value), do: {:timeout, elapsed}, else: value)}
    end)
  end

  defp retry([], _timeout, _supervisor, _context), do: %{}

  defp retry(tasks, timeout, supervisor, context) do
    retry_tasks =
      Enum.map(tasks, fn {provider, _ids, original} ->
        Task.shutdown(original, :brutal_kill)
        {original.ref, Task.Supervisor.async_nolink(supervisor, fn -> contribution(provider, context) end)}
      end)

    results = retry_tasks |> Enum.map(&elem(&1, 1)) |> Task.yield_many(timeout) |> Map.new(fn {task, result} -> {task.ref, result} end)

    Enum.reduce(retry_tasks, %{}, fn {original_ref, task}, acc ->
      result = Map.get(results, task.ref)
      if is_nil(result), do: Task.shutdown(task, :brutal_kill)
      Map.put(acc, original_ref, result)
    end)
  end

  defp boot_retry?(opts) do
    elapsed = Keyword.get(opts, :boot_elapsed_ms_fun, &Aiur.Boot.elapsed_ms/0).()
    elapsed < Keyword.get(opts, :boot_retry_window_ms, 30_000)
  end

  defp merge({provider, ids, task}, results, {caps, sections, claimed, warnings}) do
    {entries, contributed, warnings} = result(provider, ids, task, results[task.ref], warnings)
    duplicates = Enum.filter(ids, &MapSet.member?(claimed, &1))
    caps = Map.merge(caps, Map.take(entries, ids))
    caps = Enum.reduce(duplicates, caps, &Map.put(&2, &1, @unknown))
    warnings = Enum.reduce(duplicates, warnings, &MapSet.put(&2, {:duplicate, &1}))
    {caps, Map.merge(sections, contributed), Enum.reduce(ids, claimed, &MapSet.put(&2, &1)), warnings}
  end

  defp result(provider, ids, _task, {:ok, {entries, sections}}, warnings) when is_map(entries) and is_map(sections) do
    undeclared = Map.keys(entries) -- ids
    warnings = if undeclared == [], do: warnings, else: MapSet.put(warnings, {:undeclared, provider, Enum.sort(undeclared)})
    {Map.merge(Map.new(ids, &{&1, @unknown}), entries), sections, warnings}
  end

  defp result(provider, ids, task, {:timeout, elapsed_ms}, warnings) do
    Task.shutdown(task, :brutal_kill)
    detail = "timed out after #{elapsed_ms} ms"
    Logger.warning("capability provider #{inspect(provider)} #{detail}")
    {Map.new(ids, &{&1, Map.merge(@unknown, %{detail: detail})}), %{}, MapSet.put(warnings, {:failed, provider, detail})}
  end

  defp result(provider, ids, _task, {:ok, {:failed, detail}}, warnings) do
    Logger.warning("capability provider #{inspect(provider)} failed: #{detail}")
    {Map.new(ids, &{&1, Map.merge(@unknown, %{detail: detail})}), %{}, MapSet.put(warnings, {:failed, provider, detail})}
  end

  defp result(provider, ids, _task, {:exit, reason}, warnings) do
    detail = Exception.format_banner(:exit, reason)
    Logger.warning("capability provider #{inspect(provider)} failed: #{detail}")
    {Map.new(ids, &{&1, Map.merge(@unknown, %{detail: detail})}), %{}, MapSet.put(warnings, {:failed, provider, detail})}
  end

  defp result(provider, ids, _task, failure, warnings) do
    detail = inspect(failure)
    Logger.warning("capability provider #{inspect(provider)} failed: #{detail}")
    {Map.new(ids, &{&1, Map.merge(@unknown, %{detail: detail})}), %{}, MapSet.put(warnings, {:failed, provider, detail})}
  end
end
