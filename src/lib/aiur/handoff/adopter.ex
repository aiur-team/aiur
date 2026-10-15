defmodule Aiur.Handoff.Adopter do
  @moduledoc "Adopts handed-off runtimes before startup cleanup and the first poll."
  require Logger

  alias Aiur.AgentRunner.Handoff, as: Runner
  alias Aiur.AppServer.RelayPort
  alias Aiur.Config.Paths
  alias Aiur.Handoff.{Compatibility, Record}
  alias Aiur.Handoff.Fallback
  alias Aiur.Orchestrator.State

  @spec adopt(State.t(), keyword()) :: State.t()
  def adopt(state, opts \\ []) do
    case Record.read_raw(opts) do
      {:ok, record} ->
        consume(state, record, opts)

      :none ->
        state

      {:error, reason} ->
        alert(reason, opts)
        state
    end
  end

  defp consume(state, record, opts) do
    validation = Record.validate(record, opts)
    opts = Keyword.put_new_lazy(opts, :generation, fn -> generation(opts) end)

    agents =
      case record["agents"] do
        agents when is_list(agents) -> Enum.filter(agents, &is_map/1)
        _ -> []
      end

    {next, outcomes} = Enum.reduce(agents, {state, []}, &adopt_one(&1, &2, record, validation, opts))
    if match?({:error, _}, validation), do: alert(elem(validation, 1), opts)
    finish_consumption(state, next, agents, record, outcomes, opts)
  end

  defp finish_consumption(previous, next, agents, record, outcomes, opts) do
    case Record.consume(Enum.reverse(outcomes), opts) do
      :ok ->
        for {_id, entry} <- next.running, entry[:adopted_from] == record["handoff_id"], do: send(entry.pid, :handoff_continue)
        next

      {:error, reason} ->
        for {id, entry} <- next.running, not Map.has_key?(previous.running, id), do: Task.Supervisor.terminate_child(Aiur.TaskSupervisor, entry.pid)
        alert({:consume_failed, reason}, opts)

        Enum.reduce(agents, previous, fn agent, state ->
          fallback(agent, opts)
          Fallback.resume(state, agent)
        end)
    end
  end

  defp adopt_one(agent, {state, outcomes}, record, validation, opts) do
    with {:ok, _} <- validation,
         :ok <- Compatibility.check(agent, record, opts),
         {:ok, saved, budget} <- restore_metadata(agent),
         {:ok, pid, session} <- start_runner(agent, opts) do
      entry = running_entry(saved, agent, record, pid, session)
      id = agent["issue_id"]
      state = %{state | running: Map.put(state.running, id, entry), claimed: MapSet.put(state.claimed, id)}
      Logger.info("Adopted agent ticket=#{agent["identifier"]} handoff=#{record["handoff_id"]}")
      {restore_budget(state, agent["issue_id"], budget), [outcome(agent, "adopted", nil) | outcomes]}
    else
      {:error, reason} ->
        fallback(agent, opts)
        Logger.warning("Handoff fallback ticket=#{agent["identifier"]} reason=#{inspect(reason)}")
        {Fallback.resume(state, agent), [outcome(agent, "fallback", reason) | outcomes]}
    end
  rescue
    error ->
      fallback(agent, opts)
      {Fallback.resume(state, agent), [outcome(agent, "fallback", {:invalid_snapshot, Exception.message(error)}) | outcomes]}
  end

  defp start_runner(agent, opts) do
    recipient = self()
    generation = generation(opts)
    runner = Keyword.get(opts, :runner, &Runner.adopt/4)

    with {:ok, pid} <- Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> runner.(agent, generation, recipient, opts) end) do
      await_runner(pid, Keyword.get(opts, :adoption_timeout, 15_000))
    end
  end

  defp await_runner(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:handoff_adopted, ^pid, {:ok, session}} ->
        Process.demonitor(ref, [:flush])
        {:ok, pid, session}

      {:handoff_adopted, ^pid, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:runner_exit, reason}}
    after
      timeout ->
        Task.Supervisor.terminate_child(Aiur.TaskSupervisor, pid)
        Process.demonitor(ref, [:flush])
        {:error, :adoption_timeout}
    end
  end

  defp running_entry(saved, agent, record, pid, session) do
    saved
    |> Map.merge(%{pid: pid, ref: Process.monitor(pid), adopted_from: record["handoff_id"], workspace_path: agent["workspace"]})
    |> Map.put(:last_codex_timestamp, DateTime.utc_now())
    |> Map.put(:codex_app_server_pid, get_in(session, [:metadata, :codex_app_server_pid]) || get_in(agent, ["transport", "provider_pid"]))
  end

  defp restore_metadata(agent) do
    entry = Runner.decode(agent["running_entry"])
    budget = if is_binary(agent["dispatch_attempts"]), do: Runner.decode(agent["dispatch_attempts"])
    if is_map(entry) and is_binary(agent["issue_id"]), do: {:ok, entry, budget}, else: {:error, :invalid_snapshot}
  rescue
    _ -> {:error, :invalid_snapshot}
  end

  defp restore_budget(state, _id, nil), do: state
  defp restore_budget(state, id, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget[id], budget)

  defp fallback(agent, opts) do
    stop = Keyword.get(opts, :stop_agent, &Fallback.stop/1)
    stop.(agent)
    Fallback.restore_ownership(agent, opts)
  end

  defp generation(opts) do
    case Keyword.fetch(opts, :generation) do
      {:ok, generation} ->
        generation

      :error ->
        {:ok, root} = Paths.runtime_state_dir()
        RelayPort.next_generation(Path.join(root, "agent-relays"))
    end
  end

  defp outcome(agent, status, reason), do: %{identifier: agent["identifier"], status: status, reason: if(reason, do: inspect(reason))}

  defp alert(reason, opts) do
    emit = Keyword.get(opts, :emit_alert, &Aiur.Alerts.emit_system/2)

    emit.("system.handoff.incompatible",
      message: "Agent handoff could not be adopted: #{inspect(reason)}",
      reason: "Listed providers fall back to ordinary session resume.",
      needs_attention: true,
      severity: "warning",
      central: true
    )
  end
end
